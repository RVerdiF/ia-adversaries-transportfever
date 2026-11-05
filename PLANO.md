# Plano: empresas concorrentes e aquisições

## Objetivo

Evoluir o mod para uma disputa entre transportadoras, com várias rivais configuráveis, avaliação de empresas, propostas de compra e consequências econômicas. Cada etapa deve funcionar em partidas salvas e ser validada no jogo antes de servir de base para a próxima.

## Situação atual

O protótipo cria uma rival e tenta construir linhas de ônibus. O pacote foi reconhecido pelo jogo, mas construção, operação e salvamento ainda não foram comprovados numa partida. Os testes locais usam APIs simuladas. Não há menu de dificuldade, múltiplas rivais ou compra de empresas.

## 1. Validar e estabilizar a rival atual

- Iniciar uma partida nova com o mod ativado e acompanhar criação da empresa, conta, prévias, paradas, depósito, linha e ônibus transportando passageiros.
- Conferir receitas, despesas, propriedade dos bens, falhas e recuperação; salvar e carregar em momentos normais e durante uma tentativa de construção.
- Corrigir problemas observados e registrar versão do jogo, cenário, resultado e limitações. Manter testes automatizados para falhas reproduzíveis.

**Pronto quando:** uma linha opera e continua funcionando após salvar e carregar, sem despesas na conta errada ou duplicação de obras. Falhas do motor devem aparecer de maneira compreensível no painel.

## 2. Várias rivais e configurações

- Separar por empresa o estado persistido, capital, linhas, rotas, temporizadores, tentativas, histórico e diagnósticos. Acrescentar versão e migração do estado salvo da rival única.
- Criar e agendar rivais individualmente, com limite de trabalho por atualização. Coordenar reservas de locais e revalidar propostas antes de construir, inclusive depois de falhas ou carregamento.
- Oferecer inicialmente quantidade de rivais, dificuldade e perfil conservador, equilibrado ou agressivo; nome e cor configuráveis se a interface permitir. Dificuldade muda parâmetros explícitos, como reserva, frequência e tolerância a risco, sem dinheiro secreto por padrão.
- Investigar configurações nativas de início de partida; se não forem viáveis, oferecer configuração pelo painel do mod e explicar quando passam a valer. Começar com duas rivais; só ampliar o limite depois de testar desempenho e mapas pequenos.

**Pronto quando:** duas rivais constroem e operam independentemente, não repetem ações após carregar e não gastam dinheiro uma da outra. Configurações sobrevivem ao salvamento.

## 3. Contabilidade e avaliação

- Coletar saldo, dívida, veículos, linhas, infraestrutura e resultados recentes por empresa, somente onde as APIs oferecerem dados confiáveis. Definir tratamento de bens compartilhados e evitar contagem dupla.
- Exibir avaliação indicativa e seus componentes no painel. Começar com valor estimado dos ativos menos dívida, com ajuste limitado para rentabilidade recente; calibrar com exemplos de empresas lucrativas e deficitárias.
- Tratar dados ausentes como desconhecidos e bloquear operações que dependam deles, em vez de inventar valores. Exibir data e fatores da avaliação.

**Pronto quando:** o cálculo é reproduzível, explicável e testado com caixa, dívidas, prejuízos e infraestrutura compartilhada.

## 4. Prova técnica: transferência de empresas

- Investigar comandos e comportamento real do motor para transferir veículos, linhas, depósitos, estações e demais construções; identificar propriedade compartilhada, contratos, dinheiro e dívidas.
- Executar ensaios em saves descartáveis: operação dos veículos após transferência, custos de manutenção, rotas, permissões, interface, salvamento e carregamento.
- Verificar se há transação atômica ou se é necessário um processo persistido por etapas com verificação, retomada e recuperação de falhas. Não remover a empresa de origem nem cobrar duas vezes enquanto houver bens pendentes ou resultados incertos.
- Definir explicitamente o tratamento de dívidas: transferir apenas se o motor permitir e o efeito for verificável; caso contrário, restringir a operação ou exigir liquidação prévia. Se algum bem não puder mudar de dono com segurança, bloquear a aquisição completa e apresentar o motivo.

**Pronto quando:** existe uma matriz de capacidades por tipo de ativo e um teste real de transferência, inclusive com falha e recarga. O comando de mudança de proprietário exposto pela API, por si só, não comprova que todos os ativos e passivos possam ser transferidos.

## 5. Compra e venda de empresas

Implementar somente sobre capacidades comprovadas na etapa anterior.

- Mostrar valor estimado, preço ofertado, bens e passivos envolvidos, disponibilidade de caixa e consequências antes da confirmação.
- Permitir ao jogador oferecer um valor; a rival aceita, recusa ou responde com contraproposta conforme avaliação, perfil e situação financeira. Prever vencimento e cancelamento de ofertas.
- Depois, permitir ofertas entre rivais e propostas da IA ao jogador, com aceitação sempre explícita do jogador quando ele for o vendedor.
- Usar identificador único, estados persistidos e checagem de caixa/propriedade no momento da conclusão. Impedir compras duplicadas e compras simultâneas da mesma empresa. Registrar cada etapa e apresentar erros ou operações pendentes.

**Pronto quando:** compra aceita transfere apenas o que foi apresentado, cobra uma vez e sobrevive a falhas e recargas; recusa ou cancelamento não alteram bens nem saldos. Exercitar disputa por uma mesma empresa e falta de fundos.

## 6. Crise, falência e leilões

- Criar indicadores de dificuldade financeira e alertas, dando tempo para recuperação. Definir regras objetivas para insolvência e risco de falência.
- Investigar primeiro o comportamento e as regras nativas do jogo. Se suportado, oferecer venda de ativos ou leilões com lances do jogador e das rivais, reserva de dinheiro e liquidação segura.
- Evitar apagar bens, impor falência ou alterar dívidas sem confirmação de que os comandos do motor preservam a integridade da partida. Se não houver suporte, limitar a funcionalidade a avisos e propostas voluntárias.

**Pronto quando:** cenários de crise, recuperação, ausência de lances e salvamento durante o processo são verificáveis e não criam nem destroem dinheiro indevidamente.

## 7. Camada de personalidade e apresentação

- Adicionar notícias de inauguração de linhas, resultados, ofertas e aquisições; ranking de empresas com critérios visíveis e filtros.
- Evoluir perfis para especialização, reação a concorrência e tolerância a endividamento; mais tarde estudar carga, trens e expansão territorial.
- Deixar mercado de ações para uma fase posterior: exige regras próprias para participações, controle, dividendos e interface, além das mesmas garantias de transferência.

## Ordem sugerida de entrega

1. Estabilização em partida real.
2. Duas rivais e configurações básicas.
3. Painel financeiro e avaliações.
4. Experimento de transferência de ativos e decisão de viabilidade.
5. Oferta de compra do jogador, seguida de negociações entre rivais.
6. Crise e leilões, se viáveis; notícias e ranking em paralelo quando houver dados confiáveis.

Cada entrega inclui testes locais relevantes e validação no motor para o comportamento novo. Antes de atualizar o pacote distribuível, revisar documentação, compatibilidade de saves e limitações conhecidas.
