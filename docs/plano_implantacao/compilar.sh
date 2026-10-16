#!/bin/bash
# =============================================================================
# compilar.sh - Compila o .tex desta pasta em PDF.
#
# Uso:   ./compilar.sh                 (compila o único .tex da pasta)
#        ./compilar.sh plano_de_implantacao
#        ./compilar.sh --list          lista os .tex compiláveis
#        ./compilar.sh --resolve [nome] imprime o caminho do .tex e sai
#
# Por que esta versão é enxuta, e não a do /libvox_artigo_arquitetura: este
# documento não tem diagrama, não tem bibliografia e não tem .sty próprio. A
# esteira do artigo sobe um container de PlantUML e roda latexmk dentro do
# Docker, o que aqui não compra nada e traz um problema real: o latexmk guarda
# o erro da compilação anterior e passa a responder "Nothing to do" mesmo depois
# de o .tex ter sido corrigido, sem mostrar a causa. Um pdflatex direto não tem
# esse estado.
#
# Duas passadas porque o hyperref precisa da segunda para acertar os destinos.
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Trava contra build simultâneo, e não é zelo: o observar.sh dispara este script
# a cada Ctrl+S, e uma execução manual em paralelo faz dois pdflatex escreverem
# o mesmo .pdf. O resultado observado foi o PDF desaparecer da pasta. Com o
# flock, a segunda execução espera a primeira terminar.
#
# A troca de FD 9 e o re-exec acontecem uma vez só: a variável de ambiente
# impede a recursão infinita.
if [ -z "${COMPILAR_COM_TRAVA:-}" ]; then
    export COMPILAR_COM_TRAVA=1
    exec flock "$(dirname "${BASH_SOURCE[0]}")/.compilar.lock" "${BASH_SOURCE[0]}" "$@"
fi

say()  { printf '\n%s\n' "$*"; }
ok()   { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*"; }
die()  { printf '❌ %s\n' "$*" >&2; exit 1; }

# --help
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--ajuda" ]; then
    sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

# Os .tex da pasta. Um array, porque a pasta pode ganhar um segundo documento.
mapfile -t FONTES < <(ls -1 ./*.tex 2>/dev/null | sed 's|^\./||')

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "--lista" ]; then
    printf '%s\n' "${FONTES[@]:-}"
    exit 0
fi

# --resolve: o observar.sh usa isto para não divergir de qual .tex é compilado.
# Imprime caminho absoluto e nada mais; silêncio significa "não achei".
if [ "${1:-}" = "--resolve" ]; then
    alvo="${2:-}"
    if [ -n "$alvo" ]; then
        [ -f "${alvo%.tex}.tex" ] && printf '%s/%s\n' "$PWD" "${alvo%.tex}.tex"
    elif [ "${#FONTES[@]}" -eq 1 ]; then
        printf '%s/%s\n' "$PWD" "${FONTES[0]}"
    fi
    exit 0
fi

# O alvo: o argumento, ou o único .tex da pasta.
ALVO="${1:-}"
if [ -z "$ALVO" ]; then
    [ "${#FONTES[@]}" -eq 1 ] || die "Informe qual .tex compilar. Disponíveis: ${FONTES[*]:-nenhum}"
    ALVO="${FONTES[0]}"
fi
ALVO="${ALVO%.tex}"
[ -f "$ALVO.tex" ] || die "Não achei $ALVO.tex nesta pasta."

say "🚀 Compilando $ALVO.tex"

# -halt-on-error para a saída terminar no erro, e não centenas de linhas depois.
if ! pdflatex -interaction=nonstopmode -halt-on-error "$ALVO.tex" >/dev/null 2>&1; then
    printf '\n'
    grep -nE "^!|^l\.[0-9]+" "$ALVO.log" | head -20
    die "A compilação falhou (veja $ALVO.log)."
fi
pdflatex -interaction=nonstopmode -halt-on-error "$ALVO.tex" >/dev/null 2>&1

# Overfull tem tratamento próprio, e não é zelo: este documento desliga a
# hifenização (não há portuguese.ldf nesta instalação), então palavra que não
# cabe invade a margem em vez de quebrar. É o defeito mais provável aqui, e o
# log não o destaca de nada.
if grep -q "Overfull \\\\hbox" "$ALVO.log"; then
    printf '\n'
    warn "Overfull \\hbox: algo passou da margem."
    grep "Overfull \\\\hbox" "$ALVO.log" | sed 's/^/   /'
fi

# Resíduos que não servem a ninguém entre builds. O .log fica, porque é onde se
# lê o Overfull.
rm -f "$ALVO".{aux,out,toc,fls,fdb_latexmk,synctex.gz}

printf '\n'
ok "PDF gerado:"
ls -lh --time-style=+%H:%M:%S "$ALVO.pdf" | sed 's/^/   /'
