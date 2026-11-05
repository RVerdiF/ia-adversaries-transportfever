# Viação Horizonte — empresa concorrente

**Versão 2 experimental. Implementação automática disponível; ainda não validada no motor do jogo.**

Mod independente para esta instalação do Transport Fever 3. Não altera os arquivos originais.

## Ativar

1. O pacote está em `mods/release/pichau_competitor_ai`, junto aos outros pacotes locais. A cópia portátil contém essa mesma pasta.
2. Ativar **Empresa concorrente — Viação Horizonte** numa **partida livre nova**, em qualquer nível de dinheiro, e ano 1900 ou posterior. O depósito nativo começa em 1900.
3. Usar um mapa com pelo menos duas cidades conectadas por ruas públicas e espaço livre perto de pontas de rua para o depósito.
4. Abrir **Rival +** na barra para acompanhar a empresa. A construção funciona também com esse painel recolhido.

O mod cria uma empresa com nome/cor próprios e capital inicial próprio, escolhido nas opções do mod (5, 10, 20 ou 50 milhões; padrão: 10 milhões). O aporte acontece uma única vez na conta rival e não é retirado do saldo do jogador; não há empréstimos automáticos. Saves que foram bloqueados apenas por terem saldo humano zero retomam a inicialização após atualizar o mod.

## Operação automática

O planejador examina até cinco pares de cidades por atualização. Escolhe ruas públicas sem objetos para as paradas, verifica caminhos de ônibus nos dois sentidos e procura uma ponta de rua para o depósito. Exclui rotas próprias e tentativas em espera.

Cada obra passa pelo `ProposalViewer` nativo para conferir custo e colisões. O comando econômico usa a rival como proprietária. A instalação das paradas preserva a geometria das ruas; as revisões das entidades são conferidas para rejeitar fontes alteradas.

Depois de construir o depósito, o script verifica os caminhos depósito↔paradas e parada↔parada. Só então cria a linha, compra um ônibus disponível no ano e o coloca para circular. A primeira linha precisa produzir receitas e despesas reais antes de liberar novas linhas.

A política exige reserva de três meses, considerando o ônibus novo. Uma rota pode gastar até 40% do saldo restante após essa reserva. Custos reais das prévias consomem um orçamento comum da tentativa; o dinheiro do ônibus fica reservado até a compra. Não existem aportes recorrentes nem empréstimos automáticos.

A avaliação mensal usa ocupação e resultado dos veículos para ajustar a frota. O lucro de linha segue a consulta da interface nativa e não duplica infraestrutura compartilhada. Manutenção da infraestrutura entra nas contas e na reserva da empresa. A expansão é avaliada a cada três meses; limites: oito linhas e seis veículos por linha.

## Falhas e salvamento

O estado persistido contém dados simples e identificadores. Propostas e objetos nativos de caminho não são salvos. Tokens impedem que recibos repetidos ou antigos repitam obras.

Uma tentativa rejeitada entra em espera por três meses. O script tenta retirar seus próprios bens e sua linha antes de procurar outra rota. Uma falha de limpeza ou entidades sem identificação preservam a operação com um diagnóstico no painel.

Uma obra marcada como enviada que não receba confirmação não é reenviada automaticamente. Isso pode exigir conferência após carregar um save feito exatamente durante o envio. Essa pausa evita duplicar construções ou compras. Saves em etapas concluídas continuam normalmente.

## Limitações

- Uma rival e ônibus de passageiros em ruas existentes; sem ferrovias, carga ou novas estradas entre cidades.
- O depósito exige uma ponta de rua pública e espaço livre. O planejador aguarda outra avaliação se não encontrar um local, recursos ou capital suficientes.
- Parte da progressão e dos empréstimos nativos usa explicitamente o jogador humano. O mod não substitui esse jogador nem burla permissões de construções avançadas; utiliza recursos básicos permitidos. Progressão independente completa não está implementada.
- O jogo reconheceu o pacote e chegou ao menu, conforme `validation-engine.txt`. A geração das prévias, o encaixe do depósito e o transporte de passageiros ainda precisam de teste dentro de uma partida. O erro anterior de inicialização não ocorreu na última tentativa pelo diretório correto.

## Verificação local

Na pasta do mod:

```powershell
node tools/check.cjs
```

Verifica sintaxe Lua, manifestos e todos os testes em Fengari. Os testes exercitam orçamento, planejamento, construção, eventos da interface, limpeza, propriedade e persistência com substitutos das APIs C++; **não comprovam comportamento no motor**.

As ferramentas ficam em `tools/lua` e não são recursos do jogo. Para reinstalar: `npm ci --prefix tools/lua`.

## Ensaio no jogo

Criar um mapa pequeno em 2000 com cidades conectadas. Conferir painel, conta rival, paradas e depósito; verificar que o ônibus sai e transporta passageiros. Comparar receitas, construção e manutenção das empresas. Salvar/carregar após etapas concluídas e durante uma prévia, conferindo ausência de duplicação. Só depois usar em uma partida longa.
