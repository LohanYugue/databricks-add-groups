#!/bin/bash

# --- Configuração ---
ACCOUNT_HOST="https://accounts.cloud.databricks.com"

# Caminho do .env contendo ACCOUNT_ID, CLIENT_ID e CLIENT_SECRET de um service
# principal com privilégio de account-admin.
ENV_FILE="$(dirname "$0")/.env"

# Cache do access token. Reaproveitado entre execuções enquanto ainda for válido.
TOKEN_CACHE_FILE="$(dirname "$0")/.token_cache.json"

# Margem de segurança (segundos) para considerar o token expirado antes do prazo,
# evitando que ele vença no meio da execução.
TOKEN_REFRESH_MARGIN=60

# Mapeamento do nome do Perfil (Workspace) para o WORKSPACE_ID numérico.
# Esse ID é o "Workspace ID" exibido no Account Console do Databricks.
# Preencha com os workspaces da sua account.
declare -A WORKSPACE_IDS
# WORKSPACE_IDS["workspace-prd-a"]="0000000000000000"
# WORKSPACE_IDS["workspace-dev-a"]="0000000000000000"
# --- Fim da Configuração ---


# --- Validação dos Argumentos de Entrada ---
if [ -z "$1" ] || [ -z "$2" ]; then
  echo "❌ Erro: Argumentos ausentes."
  echo ""
  echo "Uso: $0 \"grupo1,grupo2\" \"perfil_ws_1,perfil_ws_2\""
  echo "Exemplo: $0 \"data-engineers,data-scientists\" \"workspace-dev-a,workspace-dev-b\""
  exit 1
fi

GROUP_LIST_CSV="$1"
WORKSPACE_LIST_CSV="$2"

# Converte as strings CSV em arrays Bash
# OBS: NÃO usar o nome "GROUPS" — é uma variável built-in do bash (array com os
# GIDs do usuário atual) e a atribuição via `read -a GROUPS` falha silenciosamente.
IFS=',' read -r -a GROUP_NAMES <<< "$GROUP_LIST_CSV"
IFS=',' read -r -a WORKSPACES <<< "$WORKSPACE_LIST_CSV"


# --- Carregamento de CLIENT_ID / CLIENT_SECRET via .env ---
if [ ! -f "$ENV_FILE" ]; then
  echo "❌ Erro: arquivo .env não encontrado em '$ENV_FILE'."
  echo "    Crie o arquivo com:"
  echo "    ACCOUNT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  echo "    CLIENT_ID=xxxxxxxx"
  echo "    CLIENT_SECRET=yyyyyyyy"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ -z "$ACCOUNT_ID" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  echo "❌ Erro: ACCOUNT_ID, CLIENT_ID e/ou CLIENT_SECRET ausentes no .env."
  exit 1
fi


# --- Geração do Access Token (válido por ~1 hora, com cache em arquivo) ---
ACCESS_TOKEN=""
NOW=$(date +%s)

# Tenta reaproveitar token do cache
if [ -f "$TOKEN_CACHE_FILE" ]; then
  CACHED_TOKEN=$(jq -r '.access_token // empty' "$TOKEN_CACHE_FILE" 2>/dev/null)
  CACHED_EXP=$(jq -r '.expires_at // 0' "$TOKEN_CACHE_FILE" 2>/dev/null)

  if [ -n "$CACHED_TOKEN" ] && [ "$CACHED_EXP" -gt $((NOW + TOKEN_REFRESH_MARGIN)) ]; then
    ACCESS_TOKEN="$CACHED_TOKEN"
    REMAINING=$((CACHED_EXP - NOW))
    echo "🔐 Reutilizando access token em cache (expira em ${REMAINING}s)."
  fi
fi

# Gera novo token se não há cache válido
if [ -z "$ACCESS_TOKEN" ]; then
  echo "🔐 Gerando novo access token na account $ACCOUNT_ID..."

  TOKEN_RESPONSE=$(curl -s --request POST \
    --url "$ACCOUNT_HOST/oidc/accounts/$ACCOUNT_ID/v1/token" \
    --user "$CLIENT_ID:$CLIENT_SECRET" \
    --data 'grant_type=client_credentials&scope=all-apis')

  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
  EXPIRES_IN=$(echo "$TOKEN_RESPONSE" | jq -r '.expires_in // 3600')

  if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo "❌ Erro: falha ao obter access token."
    echo "    Resposta: $TOKEN_RESPONSE"
    exit 1
  fi

  EXPIRES_AT=$((NOW + EXPIRES_IN))
  echo "{\"access_token\":\"$ACCESS_TOKEN\",\"expires_at\":$EXPIRES_AT}" > "$TOKEN_CACHE_FILE"
  chmod 600 "$TOKEN_CACHE_FILE"

  echo "✅ Token obtido com sucesso (válido por ${EXPIRES_IN}s)."
fi

echo ""
echo "🚀 Iniciando atribuição de grupos a workspaces..."
echo "======================================================"

# Loop 1: Iterar sobre cada WORKSPACE (perfil)
for ws_profile in "${WORKSPACES[@]}"; do
  echo ""
  echo "🔁 Processando Workspace (Perfil): $ws_profile"
  echo "------------------------------------------------------"

  # 1. Obter o ID numérico do Workspace
  WORKSPACE_ID=${WORKSPACE_IDS[$ws_profile]}

  if [ -z "$WORKSPACE_ID" ]; then
    echo "⚠️  AVISO: Nenhum WORKSPACE_ID encontrado para o perfil '$ws_profile'."
    echo "           Preencha o mapeamento WORKSPACE_IDS no início do script."
    echo "           Pulando este workspace..."
    continue
  fi

  echo "➡️  ID do Workspace: $WORKSPACE_ID"

  # Lista as atribuições atuais do workspace (uma vez por workspace) para detectar
  # grupos já atribuídos e evitar PUTs desnecessários.
  ASSIGNMENTS_RESPONSE=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$ACCOUNT_HOST/api/2.0/accounts/$ACCOUNT_ID/workspaces/$WORKSPACE_ID/permissionassignments")
  echo ""

  # Loop 2: Iterar sobre cada GRUPO para o workspace atual
  for group_name in "${GROUP_NAMES[@]}"; do
    echo "  👥 Processando Grupo: $group_name"

    # 2. Obter o ID do grupo na ACCOUNT via SCIM
    #    Tentamos o filter server-side; mas como nem sempre é respeitado, também
    #    fazemos um filtro client-side em jq por match exato de displayName.
    echo "     Buscando ID para '$group_name' na account..."
    GROUPS_RESPONSE=$(curl -s -G \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      --data-urlencode "filter=displayName eq \"$group_name\"" \
      "$ACCOUNT_HOST/api/2.0/accounts/$ACCOUNT_ID/scim/v2/Groups")

    MATCHED_IDS=$(echo "$GROUPS_RESPONSE" | jq -r --arg name "$group_name" \
      '[.Resources[]? | select(.displayName == $name) | .id] | .[]')

    MATCH_COUNT=$(echo "$MATCHED_IDS" | grep -c .)

    # 3. Validar se o ID foi encontrado
    if [ "$MATCH_COUNT" -eq 0 ]; then
      echo "     ❌ ERRO: Nenhum grupo com displayName '$group_name' encontrado na account."
      continue
    fi

    if [ "$MATCH_COUNT" -gt 1 ]; then
      echo "     ❌ ERRO: Mais de um grupo com displayName '$group_name' encontrado:"
      echo "$MATCHED_IDS" | sed 's/^/             /'
      echo "             Pulando para evitar atribuição ambígua."
      continue
    fi

    GROUP_ID="$MATCHED_IDS"
    echo "     ✅ ID do Grupo (account): $GROUP_ID"

    # 4. Verificar se o grupo já está atribuído a este workspace
    EXISTING_PERMS=$(echo "$ASSIGNMENTS_RESPONSE" | jq -r --arg pid "$GROUP_ID" \
      '[.permission_assignments[]? | select((.principal.principal_id|tostring) == $pid) | .permissions[]?] | unique | join(",")')

    if [ -n "$EXISTING_PERMS" ]; then
      echo "     ⏭️  PULANDO: grupo '$group_name' já está atribuído ao workspace '$ws_profile' (permissões: $EXISTING_PERMS)."
      echo ""
      continue
    fi

    # 5. Construir o JSON Payload — "USER" concede acesso ao workspace
    JSON_PAYLOAD='{"permissions":["USER"]}'

    # 6. Atribuir o grupo ao workspace via permissionassignments
    echo "     Atribuindo grupo $GROUP_ID ao workspace $WORKSPACE_ID..."

    HTTP_CODE=$(curl -s -o /tmp/dbx_assign_resp.json -w "%{http_code}" \
      -X PUT \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$JSON_PAYLOAD" \
      "$ACCOUNT_HOST/api/2.0/accounts/$ACCOUNT_ID/workspaces/$WORKSPACE_ID/permissionassignments/principals/$GROUP_ID")

    # 6. Verificar o status da operação
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
      echo "     🎉 SUCESSO: Grupo '$group_name' incluído no workspace '$ws_profile'."
    else
      echo "     ❌ ERRO (HTTP $HTTP_CODE): Falha ao atribuir '$group_name' ao workspace '$ws_profile'."
      echo "           Resposta: $(cat /tmp/dbx_assign_resp.json)"
    fi
    echo ""

  done # Fim do loop de grupos

done # Fim do loop de workspaces

rm -f /tmp/dbx_assign_resp.json

echo "======================================================"
echo "✅ Processo concluído."
echo "======================================================"
