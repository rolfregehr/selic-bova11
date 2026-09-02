# Minha carteira — Shiny

Painel local simples para acompanhar o Fundo Selic e o BOVA11.

Os gráficos interativos são produzidos com `echarts4r`.
O layout é responsivo: a lateral é recolhida e os cards são reorganizados automaticamente em telas menores.

## Executar

No terminal, dentro desta pasta:

```bash
R -e "shiny::runApp()"
```

O R mostrará o endereço local do app (normalmente `http://127.0.0.1:xxxx`).

## Uso diário

1. No início do dia, use **Informar saldos do início do dia** para registrar os saldos observados do Fundo Selic e do BOVA11.
2. No fim do dia, registre as compras e vendas realizadas e, quando houver, o aporte externo ou a retirada sem compra/venda correspondente.
3. Compras entram positivamente e vendas negativamente no fluxo de capital. Uma troca entre Fundo Selic e BOVA11 fica neutra quando a venda e a compra têm o mesmo valor.
4. Não repita no campo **Aporte externo** o dinheiro que já foi registrado como compra, para evitar dupla contagem.

O saldo diário do Fundo Selic é sempre o valor efetivamente informado pela manhã; a Selic do Banco Central continua sendo usada como referência de comparação. As movimentações registradas no fim de um dia passam a aparecer no saldo informado na manhã seguinte.

Os dados ficam nos arquivos `data/posicoes.csv` e `data/operacoes.csv`. Salvar novamente os saldos de uma data atualiza aquela data; operações são adicionadas ao histórico.
Em produção, a variável de ambiente `CARTEIRA_DATA_DIR` aponta para a pasta persistente, separada do código publicado.

## Dados iniciais

Foi adotado 01/09/2026 como o dia 1. O patrimônio inicial é a soma exata dos saldos informados: R$ 56.520,59 no Fundo Selic mais R$ 707,48 em BOVA11, totalizando R$ 57.228,07. A compra de R$ 176,90 do fim do dia entra como fluxo de capital a partir do saldo da manhã seguinte, sem alterar o patrimônio inicial.

A rentabilidade mostrada é uma medida simples: patrimônio atual menos patrimônio inicial e aportes líquidos posteriores, dividido pelo patrimônio inicial.

O quadro **Carteira × Selic pura** compara o patrimônio conjunto do Fundo Selic e do BOVA11 com o valor hipotético de todo o patrimônio inicial e de todos os fluxos posteriores remunerados diretamente pela série diária da Selic. Compras, vendas, aportes e retiradas entram no cálculo; a diferença mostra quanto a estratégia completa está acima ou abaixo dessa referência.

## Referência Selic

O app consulta a taxa Selic diária na série 11 do Banco Central. O acumulado é calculado por juros compostos, multiplicando os fatores diários `(1 + Selic diária)`. A linha vermelha tracejada mostra o patrimônio inicial corrigido pela Selic; aportes posteriores entram nessa referência na data em que foram registrados.
