; discrete_fractal - generator fraktali ze znaków ASCII (system L).
;
; Uruchomienie: ./discrete_fractal n
; Program czyta ze standardowego wejścia napis początkowy i reguły
; zastępowania symboli, wykonuje n iteracji zastępowania i wypisuje wynik.
;
; Algorytm
; --------
; Kolejnych napisów pośrednich nie budujemy. Wynik to sklejenie rozwinięć
; kolejnych symboli napisu początkowego, a rozwinięcie symbolu s po d
; iteracjach to sklejenie rozwinięć symboli jego reguły po d - 1 iteracjach.
; Przechodzimy więc drzewo wyprowadzenia w głąb z własnym stosem i od razu
; piszemy gotowe symbole do bufora wynikowego. Żeby czas był proporcjonalny
; do długości wyniku, a nie do liczby iteracji, stosujemy cztery skróty:
;  1. Symbol bez reguły (albo z regułą "na samego siebie") jest końcowy -
;     wypisujemy go od razu, niezależnie od liczby pozostałych iteracji.
;  2. Dla każdego symbolu liczymy "czas śmierci": liczbę iteracji, po której
;     jego rozwinięcie staje się puste (0, gdy nigdy). Poddrzewa, które
;     znikają, pomijamy w czasie stałym.
;  3. Gdy symbolowi została jedna iteracja, kopiujemy blokiem tekst reguły.
;  4. Gdy zostało więcej iteracji niż największy czas śmierci, przeżywają
;     tylko nieśmiertelne symbole reguły. Jeśli jest dokładnie jeden, to
;     symbol po prostu przechodzi w niego. Takie łańcuchy przeskakujemy,
;     a gdy łańcuch wpada w cykl, liczbę kroków bierzemy modulo jego długość.
;     Ostatni skok z każdego symbolu pamiętamy, bo zwykle się powtarza.
;
; Całe wejście, wynik i stos przeszukiwania leżą w trzech obszarach pamięci
; przydzielanych przez mmap i powiększanych przez mremap, więc jedynym
; ograniczeniem jest dostępna pamięć. Tablice pomocnicze leżą na stosie
; procesu, dzięki czemu program ma tylko sekcję .text.

global _start

SYS_READ        equ 0
SYS_WRITE       equ 1
SYS_MMAP        equ 9
SYS_MUNMAP      equ 11
SYS_MREMAP      equ 25
SYS_EXIT        equ 60

STDIN           equ 0
STDOUT          equ 1
PROT_RW         equ 3                   ; PROT_READ | PROT_WRITE
MAP_PRYWATNA    equ 0x22                ; MAP_PRIVATE | MAP_ANONYMOUS
MREMAP_MAYMOVE  equ 1
MAX_BLAD        equ 4095                ; Błędy to wyniki od -4095 do -1.

NL              equ 10                  ; znak nowej linii
SYMBOL_MIN      equ 33                  ; najmniejszy kod symbolu
SYMBOL_MAX      equ 126                 ; największy kod symbolu
LICZBA_KODOW    equ 128                 ; rozmiar tablic indeksowanych kodem

ROZMIAR_POCZ    equ 1 << 16             ; początkowy rozmiar obszaru pamięci
ZAPAS           equ 16                  ; Kopiujemy porcjami po 16 bajtów,
                                        ; więc tyle wolno wyjść poza dane.
RAMKA_STOSU     equ 16                  ; rozmiar ramki stosu przeszukiwania
LIMIT_KROKOW    equ 128                 ; Po tylu krokach łańcuch pojedynczych
                                        ; następników na pewno jest w cyklu,
                                        ; bo symboli jest mniej.

; Układ ramki na stosie procesu (przesunięcia względem rbp). Opis obszaru
; pamięci to dwa słowa: adres początku i rozmiar (zera, gdy nieprzydzielony).
WE              equ 0                   ; opis obszaru z danymi wejściowymi
WY              equ 16                  ; opis obszaru z wynikiem
STOS            equ 32                  ; opis obszaru stosu przeszukiwania
LICZBA_OBSZAROW equ 3
T_MAX           equ 48                  ; największy czas śmierci symbolu
SMIERC          equ 56                  ; bajty: czas śmierci (0 - nigdy)
JEDYNY          equ SMIERC + LICZBA_KODOW ; bajty: jedyny nieśmiertelny
                                        ; następnik symbolu (0 - brak)
JEST            equ JEDYNY + LICZBA_KODOW ; bajty: czy podano regułę
TEKST           equ JEST + LICZBA_KODOW ; adresy tekstów reguł (0 - symbol
                                        ; końcowy); tekst kończy się NL
DLUGOSC         equ TEKST + 8 * LICZBA_KODOW ; długości tekstów reguł
KLUCZ           equ DLUGOSC + 8 * LICZBA_KODOW ; pamięć skoków: liczba
                                        ; iteracji, dla której zapamiętano
                                        ; skok z symbolu (0 - nic)
WYNIK           equ KLUCZ + 8 * LICZBA_KODOW ; pamięć skoków: wynik skoku,
                                        ; 256 * liczba iteracji + symbol
ROZMIAR_RAMKI   equ WYNIK + 8 * LICZBA_KODOW

section .text

; Przeznaczenie rejestrów w całym programie:
;   rbp - adres ramki z tablicami i opisami obszarów pamięci
;   r12 - liczba iteracji n, a w czasie generowania liczba iteracji, które
;         trzeba jeszcze zastosować do symboli przeglądanego napisu
; W czasie generowania wyniku dodatkowo:
;   rsi - adres następnego symbolu przeglądanego napisu
;   rdi - adres pierwszego wolnego bajtu wyniku
;   r13 - granica zapisu wyniku (koniec obszaru pomniejszony o ZAPAS)
;   r14 - wierzchołek stosu przeszukiwania (adres pierwszej wolnej ramki)
;   r15 - koniec obszaru stosu przeszukiwania
; Pozostałe rejestry są robocze i opisane w miejscu użycia.
_start:
        mov     rdx, rsp                ; rdx - adres liczby parametrów
        sub     rsp, ROZMIAR_RAMKI
        mov     rdi, rsp
        mov     ecx, ROZMIAR_RAMKI / 8
        xor     eax, eax
        rep stosq                       ; Zeruj tablice i opisy obszarów.
        mov     rbp, rsp

; Sprawdź liczbę parametrów i zamień parametr na liczbę w r12.
        cmp     qword [rdx], 2          ; nazwa programu i jeden parametr
        jne     blad
        mov     rsi, [rdx + 16]         ; rsi - adres kolejnej cyfry
        cmp     byte [rsi], 0
        je      blad                    ; Pusty parametr nie jest liczbą.
        xor     r12d, r12d
.cyfra:
        movzx   ecx, byte [rsi]
        inc     rsi
        test    ecx, ecx
        jz      wczytaj                 ; koniec parametru
        sub     ecx, '0'
        cmp     ecx, 9
        ja      blad                    ; znak spoza zakresu '0'..'9'
        lea     r12, [r12 + 4 * r12]
        lea     r12, [rcx + 2 * r12]    ; r12 = 10 * r12 + cyfra
        mov     rax, r12
        shr     rax, 32
        jnz     blad                    ; Liczba przekroczyła 2^32 - 1.
        jmp     .cyfra

; Wczytaj całe standardowe wejście do obszaru WE.
; rbx - adres opisu obszaru, r14 - liczba wczytanych bajtów
wczytaj:
        xor     r14d, r14d
        lea     rbx, [rbp + WE]
.czytaj:
        mov     rdx, [rbx + 8]
        sub     rdx, r14
        sub     rdx, ZAPAS              ; rdx - wolne miejsce bez zapasu
        jg      .jest_miejsce
        call    powieksz                ; Brak miejsca (albo obszaru).
        jmp     .czytaj
.jest_miejsce:
        mov     rsi, [rbx]
        add     rsi, r14                ; Czytaj za dotychczasowe dane.
        xor     edi, edi                ; STDIN
        xor     eax, eax                ; SYS_READ
        syscall
        test    rax, rax
        js      blad
        jz      rozbior                 ; koniec danych
        add     r14, rax
        jmp     .czytaj

; Sprawdź poprawność danych i zapamiętaj reguły.
; rsi - adres kolejnego znaku, r8 - koniec danych
rozbior:
        test    r14, r14
        jz      blad                    ; Brakuje linii z napisem początkowym.
        mov     rsi, [rbx]
        lea     r8, [rsi + r14]
        cmp     byte [r8 - 1], NL
        jne     blad                    ; Ostatnia linia nie kończy się NL.
.napis:                                 ; Napis początkowy to same symbole.
        lodsb
        cmp     al, NL
        je      .koniec_napisu
        sub     al, SYMBOL_MIN
        cmp     al, SYMBOL_MAX - SYMBOL_MIN
        ja      blad
        jmp     .napis
.koniec_napisu:
        lea     r13, [rsi - 1]          ; r13 - adres NL po napisie początkowym
.regula:
        cmp     rsi, r8
        je      smierc                  ; Nie ma więcej linii.
        movzx   eax, byte [rsi]         ; rax - zastępowany symbol
        inc     rsi
        lea     edx, [rax - SYMBOL_MIN]
        cmp     edx, SYMBOL_MAX - SYMBOL_MIN
        ja      blad                    ; W tym także pusta linia.
        cmp     byte [rbp + JEST + rax], 0
        jne     blad                    ; druga reguła dla tego symbolu
        mov     byte [rbp + JEST + rax], 1
        mov     rdi, rsi                ; rdi - początek tekstu reguły
.tekst:                                 ; Tekst reguły to same symbole.
        movzx   edx, byte [rsi]
        inc     rsi
        cmp     dl, NL
        je      .koniec_reguly
        sub     dl, SYMBOL_MIN
        cmp     dl, SYMBOL_MAX - SYMBOL_MIN
        ja      blad
        jmp     .tekst
.koniec_reguly:
        lea     rcx, [rsi - 1]
        sub     rcx, rdi                ; rcx - długość tekstu reguły
        cmp     rcx, 1
        jne     .zapisz
        cmp     [rdi], al
        je      .regula                 ; Reguła "s na s" niczego nie zmienia,
                                        ; symbol zostaje końcowy.
.zapisz:
        mov     [rbp + TEKST + 8 * rax], rdi
        mov     [rbp + DLUGOSC + 8 * rax], rcx
        jmp     .regula

; Wyznacz czasy śmierci. Symbol znika po t iteracjach, gdy wszystkie symbole
; jego reguły znikają najpóźniej po t - 1 iteracjach (pusta reguła: t = 1).
; Powtarzamy przegląd reguł, dopóki udaje się wyznaczyć nowy czas.
; rax - badany symbol, rsi - adres znaku jego reguły, ecx - największy czas
; śmierci następników, r9d - czy coś się zmieniło, r10d - największy czas
smierc:
        xor     r10d, r10d
.runda:
        xor     r9d, r9d
        mov     eax, SYMBOL_MIN
.symbol:
        mov     rsi, [rbp + TEKST + 8 * rax]
        test    rsi, rsi
        jz      .nastepny               ; Symbol końcowy nie znika.
        cmp     byte [rbp + SMIERC + rax], 0
        jne     .nastepny               ; Czas już wyznaczony.
        xor     ecx, ecx
.znak:
        movzx   edx, byte [rsi]
        inc     rsi
        cmp     dl, NL
        je      .umiera
        movzx   edx, byte [rbp + SMIERC + rdx]
        test    edx, edx
        jz      .nastepny               ; Następnik (na razie) nie znika.
        cmp     ecx, edx
        cmovb   ecx, edx
        jmp     .znak
.umiera:
        inc     ecx                     ; O jedną iterację później niż
        mov     [rbp + SMIERC + rax], cl ; ostatni z następników.
        cmp     r10d, ecx
        cmovb   r10d, ecx
        inc     r9d
.nastepny:
        inc     eax
        cmp     eax, SYMBOL_MAX
        jbe     .symbol
        test    r9d, r9d
        jnz     .runda
        mov     [rbp + T_MAX], r10      ; Górna połowa r10 jest wyzerowana.

; Dla każdego nieśmiertelnego symbolu z regułą sprawdź, czy w tekście reguły
; jest dokładnie jedno wystąpienie nieśmiertelnego symbolu, i zapamiętaj je.
; rax - badany symbol, rsi - adres znaku reguły, ecx - znaleziony następnik
jedyny:
        mov     eax, SYMBOL_MIN
.symbol:
        mov     rsi, [rbp + TEKST + 8 * rax]
        test    rsi, rsi
        jz      .nastepny               ; symbol końcowy
        cmp     byte [rbp + SMIERC + rax], 0
        jne     .nastepny               ; symbol śmiertelny
        xor     ecx, ecx
.znak:
        movzx   edx, byte [rsi]
        inc     rsi
        cmp     dl, NL
        je      .zapisz
        cmp     byte [rbp + SMIERC + rdx], 0
        jne     .znak                   ; Śmiertelne następniki się nie liczą.
        test    ecx, ecx
        jnz     .nastepny               ; drugi nieśmiertelny następnik
        mov     ecx, edx
        jmp     .znak
.zapisz:
        mov     [rbp + JEDYNY + rax], cl
.nastepny:
        inc     eax
        cmp     eax, SYMBOL_MAX
        jbe     .symbol

; Przydziel stos przeszukiwania i bufor wyniku, wybierz napis startowy.
        lea     rbx, [rbp + STOS]
        call    powieksz
        mov     r14, [rbx]              ; Stos przeszukiwania jest pusty.
        mov     r15, [rbx + 8]
        add     r15, r14
        mov     rsi, r13                ; rsi - adres NL po napisie początkowym
        xor     edi, edi                ; Wynik jest pusty, a jego obszar
        call    powieksz_wyjscie        ; jeszcze nieprzydzielony.
        mov     rbx, [rbp + WE]         ; rbx - adres napisu początkowego
        test    r12, r12
        jnz     .iteruj
        mov     rcx, rsi                ; Bez iteracji wynikiem jest napis
        sub     rcx, rbx                ; początkowy: skopiuj go blokiem.
        jmp     kopiuj.sprawdz          ; rsi wskazuje NL, więc potem koniec.
.iteruj:
        mov     rsi, rbx

; Główna pętla: weź kolejny symbol przeglądanego napisu. Zawsze r12 >= 1.
; rax - symbol, rbx - adres tekstu jego reguły, rdx - liczba iteracji,
; które trzeba jeszcze zastosować do tego symbolu
petla:
        movzx   eax, byte [rsi]
        inc     rsi
        cmp     al, NL
        je      koniec_napisu
        movzx   edx, byte [rbp + SMIERC + rax]
        dec     edx                     ; Dla nieśmiertelnego daje 2^32 - 1,
        cmp     rdx, r12                ; czyli co najmniej tyle, ile r12.
        jb      petla                   ; Czas śmierci <= r12: symbol znika.
        mov     rbx, [rbp + TEKST + 8 * rax]
        test    rbx, rbx
        jz      wypisz                  ; symbol końcowy
        mov     rdx, r12
        cmp     rdx, [rbp + T_MAX]
        jbe     zejdz                   ; Mogą przeżyć śmiertelne następniki.
        cmp     byte [rbp + JEDYNY + rax], 0
        jne     skok                    ; Przeżyje tylko jeden następnik.

; Zastąp symbol tekstem jego reguły: przejdź do przeglądania tego tekstu.
; rbx - adres tekstu reguły, rdx - liczba iteracji dla symbolu (co najmniej 1)
zejdz:
        dec     rdx                     ; rdx - liczba iteracji dla następników
        jz      kopiuj                  ; Następniki są już końcowe.
        cmp     byte [rsi], NL
        je      .bez_powrotu            ; Symbol był ostatni w napisie, więc
                                        ; nie ma po co do niego wracać.
        cmp     r14, r15
        jae     .powieksz_stos
.odloz:
        mov     [r14], rsi              ; Zapamiętaj miejsce powrotu
        mov     [r14 + 8], r12          ; i liczbę iteracji dla tego napisu.
        add     r14, RAMKA_STOSU
.bez_powrotu:
        mov     rsi, rbx
        mov     r12, rdx
        jmp     petla
.powieksz_stos:                         ; Stos jest pełny: r14 = r15.
        push    rbx
        push    rdx
        lea     rbx, [rbp + STOS]
        call    powieksz                ; Podwaja rozmiar obszaru.
        mov     r14, [rbx]
        mov     r15, [rbx + 8]
        mov     rax, r15
        shr     rax, 1
        add     r15, r14                ; nowy koniec obszaru
        add     r14, rax                ; Wierzchołek jest w połowie obszaru.
        pop     rdx
        pop     rbx
        jmp     .odloz

; Skopiuj do wyniku tekst reguły symbolu, któremu została jedna iteracja.
; rax - symbol, rbx - adres tekstu, rcx - długość tekstu
kopiuj:
        mov     rcx, [rbp + DLUGOSC + 8 * rax]
.sprawdz:
        lea     rax, [rdi + rcx]
        cmp     rax, r13
        ja      .powieksz               ; Tekst nie mieści się w buforze.
        xor     eax, eax                ; rax - liczba skopiowanych bajtów
.porcja:                                ; Kopiuj po 16 bajtów. Nadmiarowe
        movdqu  xmm0, [rbx + rax]       ; bajty mieszczą się w zapasach obu
        movdqu  [rdi + rax], xmm0       ; obszarów i zostaną nadpisane.
        add     rax, 16
        cmp     rax, rcx
        jb      .porcja
        add     rdi, rcx
        jmp     petla
.powieksz:
        call    powieksz_wyjscie
        jmp     .sprawdz

; Dopisz do wyniku symbol z rejestru al.
wypisz:
        cmp     rdi, r13
        jae     .powieksz
.zapisz:
        stosb
        jmp     petla
.powieksz:
        call    powieksz_wyjscie
        jmp     .zapisz

; Przeglądany napis się skończył: wróć do napisu, z którego pochodził symbol.
koniec_napisu:
        cmp     r14, [rbp + STOS]
        je      gotowe                  ; Pusty stos: to był napis początkowy.
        sub     r14, RAMKA_STOSU
        mov     rsi, [r14]
        mov     r12, [r14 + 8]
        jmp     petla

; Przeskocz łańcuch symboli, z których każdy przechodzi w jeden symbol.
; Wejście: rax - symbol mający jedynego następnika, rdx - liczba iteracji dla
; tego symbolu, większa niż T_MAX. Wyjście: rax - symbol równoważny, rdx -
; liczba iteracji dla niego. Krok wolno zrobić, dopóki rdx > T_MAX.
; r8, r9 - symbol i liczba iteracji z wejścia (klucz pamięci skoków)
skok:
        cmp     rdx, [rbp + KLUCZ + 8 * rax]
        je      .z_pamieci              ; Taki skok był już liczony.
        mov     r8d, eax
        mov     r9, rdx
        mov     ecx, LIMIT_KROKOW       ; ecx - ile kroków wolno zrobić wprost
.krok:
        movzx   eax, byte [rbp + JEDYNY + rax]
        dec     rdx
        cmp     byte [rbp + JEDYNY + rax], 0
        je      .koniec                 ; Symbol nie ma jedynego następnika.
        cmp     rdx, [rbp + T_MAX]
        jbe     .koniec
        dec     ecx
        jnz     .krok
        mov     ebx, eax                ; Jesteśmy w cyklu. Policz w ecx jego
.dlugosc:                               ; długość, obchodząc go od rax do rax.
        movzx   ebx, byte [rbp + JEDYNY + rbx]
        inc     ecx
        cmp     ebx, eax
        jne     .dlugosc                ; Po pętli ebx = eax.
        mov     rax, rdx
        sub     rax, [rbp + T_MAX]      ; Tyle kroków zostało do zrobienia.
        xor     edx, edx
        div     rcx                     ; rdx - liczba kroków modulo długość
        mov     eax, ebx
        test    edx, edx
        jz      .po_cyklu
.obieg:
        movzx   eax, byte [rbp + JEDYNY + rax]
        dec     edx
        jnz     .obieg
.po_cyklu:
        mov     rdx, [rbp + T_MAX]      ; Wszystkie kroki zostały zrobione.
.koniec:
        mov     [rbp + KLUCZ + 8 * r8], r9 ; Zapamiętaj wynik skoku.
        mov     rcx, rdx
        shl     rcx, 8                  ; Liczba iteracji ma najwyżej 32 bity.
        or      rcx, rax
        mov     [rbp + WYNIK + 8 * r8], rcx
.wynik:
        test    rdx, rdx
        jz      wypisz                  ; Nie ma już iteracji dla symbolu.
        mov     rbx, [rbp + TEKST + 8 * rax]
        test    rbx, rbx
        jz      wypisz                  ; symbol końcowy
        jmp     zejdz
.z_pamieci:
        mov     rdx, [rbp + WYNIK + 8 * rax]
        movzx   eax, dl                 ; symbol z najmłodszego bajtu
        shr     rdx, 8
        jmp     .wynik

; Wynik jest gotowy: dopisz znak nowej linii i wypisz całość.
gotowe:
        cmp     rdi, r13
        jb      .nowa_linia
        call    powieksz_wyjscie
.nowa_linia:
        mov     al, NL
        stosb
        mov     rsi, [rbp + WY]         ; rsi - adres niewypisanej części
        mov     rdx, rdi
        sub     rdx, rsi                ; rdx - liczba niewypisanych bajtów
.pisz:
        mov     eax, SYS_WRITE
        mov     edi, STDOUT
        syscall
        test    rax, rax
        jle     blad
        add     rsi, rax                ; Funkcja mogła wypisać tylko część.
        sub     rdx, rax
        jnz     .pisz
        xor     r12d, r12d              ; kod zakończenia 0
        jmp     sprzataj

; Zakończenie programu. Do etykiety blad skaczemy po wykryciu błędu.
; Zwalniamy wszystkie przydzielone obszary; r12d - kod zakończenia,
; rbx - adres opisu obszaru, r13d - liczba opisów do sprawdzenia
blad:
        mov     r12d, 1
sprzataj:
        lea     rbx, [rbp + WE]
        mov     r13d, LICZBA_OBSZAROW
.obszar:
        mov     rdi, [rbx]
        test    rdi, rdi
        jz      .nastepny               ; Obszar nie został przydzielony.
        mov     rsi, [rbx + 8]
        mov     eax, SYS_MUNMAP
        syscall
        test    rax, rax
        jz      .nastepny
        mov     r12d, 1                 ; Zwalnianie się nie powiodło.
.nastepny:
        add     rbx, 16
        dec     r13d
        jnz     .obszar
        mov     edi, r12d
        mov     eax, SYS_EXIT
        syscall

; Przydziela obszar pamięci o rozmiarze ROZMIAR_POCZ, a jeśli już istnieje,
; podwaja jego rozmiar (obszar może przy tym zmienić adres). Przy błędzie
; kończy program.
; Wejście: rbx - adres opisu obszaru (opis zostaje uaktualniony).
; Modyfikuje rejestry rax, rcx, rdx, r8, r9, r10, r11.
powieksz:
        push    rsi
        push    rdi
        mov     rsi, [rbx + 8]          ; rsi - obecny rozmiar
        test    rsi, rsi
        jnz     .podwoj
        mov     eax, SYS_MMAP
        xor     edi, edi                ; Adres wybierze system.
        mov     esi, ROZMIAR_POCZ
        mov     edx, PROT_RW
        mov     r10d, MAP_PRYWATNA
        or      r8, -1                  ; Obszar nie jest związany z plikiem.
        xor     r9d, r9d
        syscall
        jmp     .sprawdz
.podwoj:
        mov     eax, SYS_MREMAP
        mov     rdi, [rbx]
        lea     rdx, [rsi + rsi]        ; nowy rozmiar
        mov     r10d, MREMAP_MAYMOVE
        syscall
        mov     rsi, rdx
.sprawdz:
        cmp     rax, -MAX_BLAD
        jae     blad                    ; Stary obszar zwolni sprzątanie.
        mov     [rbx], rax
        mov     [rbx + 8], rsi          ; rsi - rozmiar po zmianie
        pop     rdi
        pop     rsi
        ret

; Powiększa bufor wyniku (także wtedy, gdy jeszcze go nie ma).
; Uaktualnia rdi i r13. Modyfikuje rdx, r8, r9, r10, r11.
powieksz_wyjscie:
        push    rax
        push    rbx
        push    rcx
        lea     rbx, [rbp + WY]
        sub     rdi, [rbx]              ; rdi - długość wyniku
        call    powieksz
        mov     r13, [rbx]
        add     rdi, r13                ; to samo miejsce w nowym obszarze
        add     r13, [rbx + 8]
        sub     r13, ZAPAS
        pop     rcx
        pop     rbx
        pop     rax
        ret