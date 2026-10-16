#!/bin/bash
# =============================================================================
# observar.sh - Observa os fontes do artigo e recompila ao salvar.
#
# Ao salvar o .tex (ou qualquer .puml/.bib/.sty da mesma pasta), dispara
# automaticamente o ./compilar.sh, que regenera os diagramas (se houver pasta
# puml) e o PDF.
#
# Uso:   ./observar.sh                 (observa o único .tex da pasta)
#        ./observar.sh artigo          (quando há mais de um .tex)
#        ./observar.sh artigo --rm
#
# Requer o 'entr'.  Ctrl+C encerra a observacao.
# =============================================================================

# 1. Diretorio do script (a pasta do artigo) -- garante caminhos consistentes.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 2. --help: mostra o modo de uso.
if [ "$1" == "--help" ] || [ "$1" == "-h" ] || [ "$1" == "--ajuda" ]; then
    echo "Uso: ./observar.sh [nome] [--rm] [--fresh]"
    echo "     (sem argumento, observa o único .tex da pasta)"
    exit 0
fi

# 3. Verifica se o 'entr' esta instalado.
if ! command -v entr >/dev/null 2>&1; then
    echo "❌ 'entr' não encontrado."
    echo "   Instale com: sudo apt-get install entr   (Debian/Ubuntu)"
    exit 1
fi

# 4. Separa o alvo (opcional) das flags repassadas ao compilar.sh.
ALVO=""
case "$1" in
    ""|-*) ;;
    *)     ALVO="$1"; shift ;;
esac
EXTRA=("$@")   # repassa --rm/--fresh ao compilar.sh, se informados

# 5. Reaproveita a resolucao de alvo do compilar.sh (modo --resolve): assim as
#    duas ferramentas nunca divergem sobre qual .tex e compilado.
FONTE=$("$SCRIPT_DIR/compilar.sh" --resolve "$ALVO")

if [ -z "$FONTE" ]; then
    if [ -n "$ALVO" ]; then
        echo "❌ Não encontrei o fonte de '$ALVO'."
    else
        echo "❌ Informe qual .tex observar (há mais de um, ou nenhum, nesta pasta)."
    fi
    echo "   Fontes disponíveis:"
    "$SCRIPT_DIR/compilar.sh" --list | sed 's/^/     /'
    exit 1
fi

echo "👀 Observando '$(basename "$FONTE")' (.tex, .sty, .bib e .puml)."
echo "   Salve para recompilar. Ctrl+C para sair."

# 6. Monta a lista de arquivos a observar e entrega ao entr:
#    - o .tex do artigo e os .sty/.bib da mesma pasta;
#    - todos os .puml da pasta puml (se existir).
#    entr executa o compilar.sh uma vez ao iniciar e a cada alteracao salva.
#    -c limpa a tela antes de cada execucao.
{
    echo "$FONTE"
    ls "$SCRIPT_DIR"/*.sty "$SCRIPT_DIR"/*.bib 2>/dev/null
    ls "$SCRIPT_DIR"/puml/*.puml 2>/dev/null
} | entr -c "$SCRIPT_DIR/compilar.sh" "$(basename "$FONTE" .tex)" "${EXTRA[@]}"
