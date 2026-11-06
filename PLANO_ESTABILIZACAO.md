# Plano de estabilização: modo caveman

Objetivo: uma rival com conta própria, **uma** linha de ônibus e **um** veículo operando. Expansão, compra adicional e fechamento de linhas ficam desligados até esse percurso funcionar no jogo e sobreviver a salvar/carregar.

## O que sabemos

- O jogo rejeitou callbacks de `api.cmd.sendCommand` no GameScript (`Callbacks are currently disallowed`). A [API oficial de comandos](https://wiki.transportfever3.com/script-doc/api/cmd.html) documenta o callback como opcional e a execução dependente do contexto. Os scripts nativos de simulação usam comandos sem callback. Portanto, resultado de comando precisa ser confirmado por dados observáveis ou recebido por evento da interface.
- A revisão 9 tentou listar `ComponentType.PLAYER`; o motor respondeu `Cannot loop over this component type` em `native.lua:53`. A [API oficial de leitura](https://wiki.transportfever3.com/script-doc/api/engine.html) documenta `getEntitiesWithComponent`, mas não garante que todo tipo de componente possa ser enumerado. `getPlayer()` retorna apenas o jogador atual.
- O wrapper em `competitor.script.tl` apaga `pending` quando captura um erro. Isso perde a informação de que um comando pode ter sido enviado. A reconciliação de `create_player` e `fund` já ocorre antes do bloqueio genérico de `pending`; esse ponto deve ser preservado.
- A [página oficial de Game Scripts](https://wiki.transportfever3.com/doku.php?id=modding%3Ascripting%3Agamescripts) declara que ainda não foi adaptada ao TF3. Tipos e exemplos são ponto de partida; a aceitação real precisa ser demonstrada no jogo.

## Contrato simples

1. Um estado persistente registra `phase`, `token`, `playerId`, `pending`, `capitalTarget` e os IDs da única linha e do único ônibus. Um comando com efeito no mundo por atualização, sempre depois de gravar o marcador de intenção.
2. Nenhum GameScript passa callback a `sendCommand`. Nenhum código enumera `PLAYER`. O ID da rival só entra no estado por recibo documentado e validado: `resultEntity` do `GameAddPlayerCommandData`, entregue ao motor por evento da interface. A [API oficial](https://wiki.transportfever3.com/script-doc/api/cmd.html) define esse campo; o caminho concreto do recibo precisa passar pelo ensaio abaixo.
3. Após emitir um comando, validar o efeito com `getComponent`, propriedade, saldo e IDs conhecidos. Resultado ausente ou ambíguo vira `blocked` **sem novo envio automático**. O painel mostra fase, comando pendente e motivo curto; o log guarda o detalhe.
4. Salvamento nunca guarda userdata, callbacks ou objetos `Command`. Apenas números, strings, booleanos e tabelas simples. O tratador de exceção preserva o marcador `pending`.

## Execução em etapas

### 0. Ensaio de contrato, em partida descartável

Criar uma revisão diagnóstica pequena, separada da IA automática. Em uma única execução, registrar presença e tipo das chamadas usadas, testar com `pcall` apenas consultas sem efeito e testar uma criação de rival **uma vez**. Primeiro experimentar `makeGameAddPlayerCmd` na interface, com callback e `resultEntity`; enviar esse ID como evento primitivo para o GameScript. O motor verifica `getComponent(id, PLAYER)`, nome e `id ~= getPlayer()`. Confirmar também que `getLinesForPlayer` e `getDepotVehicles` funcionam no jogo. Não usar `getEntitiesWithComponent(PLAYER)` nem procurar IDs por força bruta.

**Segue** se o recibo traz um ID verificável e os comandos necessários aceitam o contexto. **Para** se o callback da interface ou o evento não entregar o ID. Nesse caso, não há base para criar outra empresa com segurança; procurar alternativa documentada antes de tocar no save real.

### 1. Criar e capitalizar só a empresa

Em `native.lua`, remover `playersNamed`. Em `controller.lua` e no bridge da interface (`panel.script.tl`/novo módulo), usar `create_requested` → evento de início reconhecido pelo motor → `create_sent` → recibo com ID → `fund`. O motor persiste `create_sent` **antes** de a interface enviar o comando. Se carregar `create_sent` sem recibo, bloquear e pedir reconciliação manual; nunca criar de novo. Testar com a interface aberta e recolhida.

Para financiar, usar o ID validado; guardar saldo humano anterior e meta da rival; emitir o lançamento uma vez, sem callback no GameScript; confirmar saldo rival exato e saldo humano inalterado. Se houver dúvida após carregar, bloquear sem repetir lançamento. O erro atual de `playersNamed` ocorre antes do envio do comando de criação: somente saves bloqueados por esse erro exato, sem `playerId`, `pending` ou operação, podem migrar automaticamente para a nova fase. Outros saves bloqueados exigem inspeção.

**Segue** quando uma partida nova e um save recarregado têm exatamente a mesma rival, saldo escolhido e nenhum segundo comando de criação/capitalização.

### 2. Uma rota, sem política de expansão

Desligar gestão de frota, venda, fechamento e novas rotas. Escolher uma rota rodoviária curta pelo planejador existente, mas aplicar custo/colisão pela prévia nativa na interface. Confirmar as duas paradas, o depósito, a linha própria (`getLinesForPlayer`) e o ônibus comprado (`getDepotVehicles`) antes de passar à ação seguinte. Guardar cada ID confirmado. Se uma criação não tiver resultado único, preservar a operação e bloquear; não limpar bens que não podem ser atribuídos à tentativa.

**Segue** somente quando a linha aparece na empresa rival, um ônibus está atribuído e roda por alguns meses sem erro. Testar também salvar/carregar após parada, linha e compra.

### 3. Reativar recursos aos poucos

Primeiro observação de receita/despesa; depois compra adicional; por último expansão e fechamento. Cada comando novo passa pelo mesmo ensaio de contrato e por uma transição persistente. Nenhuma etapa entra na revisão distribuída por ter passado apenas nos mocks Lua.

## Verificação e entrega

- `tools/check.cjs` continua como filtro de sintaxe, manifesto e lógica simulada. Adicionar testes que rejeitam callback em GameScript, rejeitam enumeração de `PLAYER` e reproduzem carregar durante `pending`.
- Em partida descartável, capturar um log por fase e verificar o painel. Matriz mínima: novo jogo, salvar/carregar antes e depois de cada comando, capital 10/20 milhões, jogo normal e `No Costs`, sem dinheiro humano.
- Só atualizar staging, ZIP e remoto depois que a fase correspondente passar **no jogo**. Ao falhar, registrar a chamada, o contexto e o retorno real antes de alterar a implementação. Uma revisão por fase; não publicar um conjunto grande de hipóteses como correção confirmada.
