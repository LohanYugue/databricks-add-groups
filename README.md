# databricks-add-groups

Script Bash para atribuir grupos da **account** do Databricks a um ou mais **workspaces**, em lote, via Account API com OAuth M2M (service principal).

## O que o script faz

1. Lê `ACCOUNT_ID`, `CLIENT_ID` e `CLIENT_SECRET` de um `.env` local.
2. Gera um access token OAuth (`client_credentials`, scope `all-apis`) na account informada e o reutiliza entre execuções via cache em `.token_cache.json` (renovado automaticamente quando expira).
3. Para cada `(workspace, grupo)`:
   - Resolve o `principal_id` do grupo na account via SCIM (match exato de `displayName`).
   - Verifica se o grupo já está atribuído ao workspace — se já estiver, pula.
   - Caso contrário, atribui o grupo com permissão `USER` (acesso ao workspace, sem admin).

## Pré-requisitos

- `curl` e `jq` instalados.
- Um service principal a nível de account com role de account-admin e um par `client_id` / `client_secret`.
- Os `WORKSPACE_ID` numéricos dos workspaces (visíveis no Account Console) precisam ser preenchidos no mapa `WORKSPACE_IDS` no topo do script antes do primeiro uso.

## Configuração

Crie um arquivo `.env` ao lado do script:

```env
ACCOUNT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
CLIENT_ID=xxxxxxxxxxxxxxxx
CLIENT_SECRET=yyyyyyyyyyyyyyyyyyyyyyyy
```

> ⚠️ O `.env` e o `.token_cache.json` contêm credenciais — já estão no `.gitignore` deste repo.

## Uso

```bash
./add_groups_to_workspaces.sh "grupo1,grupo2" "perfil_ws_1,perfil_ws_2"
```

Onde:

- **Argumento 1** — lista de `displayName`s de grupos da account, separados por vírgula.
- **Argumento 2** — lista de perfis de workspace (chaves do mapa `WORKSPACE_IDS` no script), separados por vírgula.

### Exemplo

Atribuir os grupos `data-engineers` e `data-scientists` aos workspaces `workspace-dev-a` e `workspace-dev-b`:

```bash
./add_groups_to_workspaces.sh \
  "data-engineers,data-scientists" \
  "workspace-dev-a,workspace-dev-b"
```

## Mapeamento de workspaces

O script depende do mapa `WORKSPACE_IDS` (no topo de [`add_groups_to_workspaces.sh`](add_groups_to_workspaces.sh)) para converter o nome de perfil do workspace no `WORKSPACE_ID` numérico exigido pela Account API.

Preencha o mapa com seus próprios workspaces:

```bash
declare -A WORKSPACE_IDS
WORKSPACE_IDS["workspace-prd-a"]="0000000000000000"
WORKSPACE_IDS["workspace-dev-a"]="0000000000000000"
```

O `WORKSPACE_ID` é o número exibido no Account Console do Databricks em **Workspaces → (workspace) → Workspace ID**.

## Saída esperada

```text
🔐 Reutilizando access token em cache (expira em 3540s).

🚀 Iniciando atribuição de grupos a workspaces...
======================================================

🔁 Processando Workspace (Perfil): workspace-dev-a
------------------------------------------------------
➡️  ID do Workspace: 0000000000000000

  👥 Processando Grupo: data-engineers
     Buscando ID para 'data-engineers' na account...
     ✅ ID do Grupo (account): 000000000000000
     Atribuindo grupo 000000000000000 ao workspace 0000000000000000...
     🎉 SUCESSO: Grupo 'data-engineers' incluído no workspace 'workspace-dev-a'.

======================================================
✅ Processo concluído.
======================================================
```

Se o grupo já estiver atribuído, aparece `⏭️ PULANDO` em vez do `🎉 SUCESSO`.

## Troubleshooting

- **`Nenhum grupo com displayName 'X' encontrado na account`** — o grupo não existe a nível de account, ou o nome está com typo / case errado. Confira no Account Console.
- **`HTTP 401 / 403`** — o service principal do `.env` não tem privilégio de account-admin, ou as credenciais estão expiradas. Apague `.token_cache.json` e tente de novo.
- **`Mais de um grupo com displayName 'X' encontrado`** — existem grupos homônimos na account; resolva renomeando ou ajuste o script para selecionar pelo `id` direto.
