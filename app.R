library(shiny)
library(bslib)
library(echarts4r)
library(scales)

options(shiny.autoreload = TRUE)

data_dir <- Sys.getenv("CARTEIRA_DATA_DIR", unset = "data")
positions_file <- file.path(data_dir, "posicoes.csv")
operations_file <- file.path(data_dir, "operacoes.csv")

dir.create(data_dir, showWarnings = FALSE, recursive = TRUE)

empty_positions <- function() {
  data.frame(
    data = as.Date(character()),
    fundo_selic = numeric(),
    bova11 = numeric(),
    aporte = numeric(),
    retirada = numeric(),
    observacao = character(),
    stringsAsFactors = FALSE
  )
}

empty_operations <- function() {
  data.frame(
    id = integer(),
    data = as.Date(character()),
    tipo = character(),
    ativo = character(),
    valor = numeric(),
    observacao = character(),
    stringsAsFactors = FALSE
  )
}

read_positions <- function() {
  if (!file.exists(positions_file)) return(empty_positions())
  x <- read.csv(positions_file, stringsAsFactors = FALSE, check.names = FALSE)
  x$data <- as.Date(x$data)
  x[order(x$data), , drop = FALSE]
}

read_operations <- function() {
  if (!file.exists(operations_file)) return(empty_operations())
  x <- read.csv(operations_file, stringsAsFactors = FALSE, check.names = FALSE)
  x$data <- as.Date(x$data)
  x[order(x$data, x$id), , drop = FALSE]
}

write_csv_safely <- function(x, path) {
  tmp <- tempfile(pattern = "investimentos-", tmpdir = dirname(path), fileext = ".csv")
  write.csv(x, tmp, row.names = FALSE, na = "")
  if (!file.rename(tmp, path)) {
    unlink(tmp)
    stop("Não foi possível salvar os dados.", call. = FALSE)
  }
}

brl <- label_currency(prefix = "R$ ", big.mark = ".", decimal.mark = ",", accuracy = 0.01)
pct <- label_percent(decimal.mark = ",", accuracy = 0.01)

fetch_selic <- function(start_date, end_date) {
  start_date <- as.Date(start_date)
  end_date <- max(as.Date(end_date), Sys.Date())
  url <- paste0(
    "https://api.bcb.gov.br/dados/serie/bcdata.sgs.11/dados?formato=json",
    "&dataInicial=", format(start_date, "%d/%m/%Y"),
    "&dataFinal=", format(end_date, "%d/%m/%Y")
  )

  old_timeout <- getOption("timeout")
  on.exit(options(timeout = old_timeout), add = TRUE)
  options(timeout = 8)

  tryCatch({
    raw <- jsonlite::fromJSON(url)
    dates <- as.Date(raw$data, format = "%d/%m/%Y")
    data.frame(
      data = dates,
      taxa = as.numeric(sub(",", ".", raw$valor, fixed = TRUE)) / 100,
      stringsAsFactors = FALSE
    )
  }, error = function(e) {
    data.frame(data = as.Date(character()), taxa = numeric())
  })
}

selic_factor <- function(selic, from, to) {
  rates <- selic$taxa[selic$data > as.Date(from) & selic$data <= as.Date(to)]
  if (!length(rates)) 1 else prod(1 + rates, na.rm = TRUE)
}

operation_flows <- function(operations, dates, asset = NULL) {
  flows <- numeric(length(dates))
  if (!is.null(asset)) {
    operations <- operations[operations$ativo == asset, , drop = FALSE]
  }
  if (!nrow(operations)) return(flows)

  signed_values <- ifelse(
    operations$tipo == "Compra",
    operations$valor,
    ifelse(operations$tipo == "Venda", -operations$valor, 0)
  )
  totals <- tapply(signed_values, operations$data, sum, na.rm = TRUE)
  matched <- match(as.character(dates), names(totals))
  found <- !is.na(matched)
  flows[found] <- unname(totals[matched[found]])
  flows
}

ui <- page_sidebar(
  title = "Minha carteira",
  theme = bs_theme(version = 5, bootswatch = "flatly", primary = "#166534"),
  fillable = FALSE,
  tags$head(tags$link(rel = "stylesheet", type = "text/css", href = "styles.css")),
  sidebar = sidebar(
    width = 320,
    class = "compact-sidebar",
    gap = "0.3rem",
    padding = c("0.55rem", "0.7rem"),
    open = "desktop",
    tags$a(
      "Abrir SELIC × BOVA11",
      href = "https://apos.rolfregehr.com.br/",
      class = "btn btn-outline-primary w-100 mb-2",
      `aria-label` = "Abrir painel SELIC versus BOVA11"
    ),
    h4("Operações do fim do dia"),
    p(class = "help-copy", "Compras e vendas entram no fluxo de capital. Uma troca entre os dois ativos fica neutra quando os valores são iguais."),
    dateInput("operation_date", "Data", value = Sys.Date(), format = "dd/mm/yyyy", language = "pt-BR"),
    div(
      class = "asset-operation asset-operation-selic",
      h5("Fundo Selic"),
      layout_columns(
        col_widths = c(6, 6),
        gap = "0.35rem",
        selectInput("selic_operation_type", "Operação", choices = c("Nenhuma", "Compra", "Venda")),
        numericInput("selic_operation_value", "Valor (R$)", value = 0, min = 0, step = 0.01)
      )
    ),
    div(
      class = "asset-operation asset-operation-bova",
      h5("BOVA11"),
      layout_columns(
        col_widths = c(6, 6),
        gap = "0.35rem",
        selectInput("bova_operation_type", "Operação", choices = c("Nenhuma", "Compra", "Venda")),
        numericInput("bova_operation_value", "Valor (R$)", value = 0, min = 0, step = 0.01)
      )
    ),
    layout_columns(
      col_widths = c(6, 6),
      gap = "0.35rem",
      numericInput("contribution", "Aporte externo", value = 0, min = 0, step = 0.01),
      numericInput("withdrawal", "Retirada", value = 0, min = 0, step = 0.01)
    ),
    textInput("operation_note", "Observação", placeholder = "Opcional"),
    actionButton("save_operation", "Registrar operação", class = "btn-primary w-100"),
    actionButton("open_position", "Informar saldos do início do dia", class = "btn-outline-secondary w-100 mt-2"),
    hr(),
    actionButton("refresh_selic", "Atualizar Selic", class = "btn-outline-primary w-100"),
    textOutput("selic_status"),
    hr(),
    downloadButton("download_positions", "Baixar saldos", class = "btn-outline-secondary w-100"),
    downloadButton("download_operations", "Baixar operações", class = "btn-outline-secondary w-100 mt-2")
  ),
  layout_column_wrap(
    class = "metric-grid",
    width = "145px",
    height = "68px",
    height_mobile = "68px",
    min_height = "68px",
    max_height = "68px",
    fill = FALSE,
    fillable = FALSE,
    value_box(title = "Patrimônio atual", value = textOutput("current_total", inline = TRUE), showcase = "R$", showcase_layout = "left center", height = "68px", fill = FALSE, class = "metric-card metric-1"),
    value_box(title = "Resultado líquido", value = textOutput("net_result", inline = TRUE), showcase = "↗", showcase_layout = "left center", height = "68px", fill = FALSE, class = "metric-card metric-2"),
    value_box(title = "Rentabilidade", value = textOutput("net_return", inline = TRUE), showcase = "%", showcase_layout = "left center", height = "68px", fill = FALSE, class = "metric-card metric-3"),
    value_box(title = "Aportes líquidos", value = textOutput("net_contributions", inline = TRUE), showcase = "↔", showcase_layout = "left center", height = "68px", fill = FALSE, class = "metric-card metric-4"),
    value_box(title = "Selic acumulada", value = textOutput("accumulated_selic", inline = TRUE), showcase = "Selic", showcase_layout = "left center", height = "68px", fill = FALSE, class = "metric-card metric-5")
  ),
  layout_columns(
    col_widths = c(8, 4),
    fill = FALSE,
    fillable = FALSE,
    card(
      full_screen = TRUE,
      card_header("Evolução do patrimônio"),
      echarts4rOutput("wealth_plot", height = "290px"),
    card_footer("Referência: patrimônio inicial e aplicações líquidas posteriores corrigidos pela Selic diária.")
    ),
    card(
      card_header("Composição atual"),
      echarts4rOutput("composition_plot", height = "320px")
    )
  ),
  layout_columns(
    col_widths = c(8, 4),
    fill = FALSE,
    fillable = FALSE,
    card(
      full_screen = TRUE,
      fill = FALSE,
      card_header("Saldos no início do dia"),
      div(class = "table-scroll", tableOutput("positions_table")),
      card_footer("Compras, vendas, aportes e retiradas entram no fluxo do fim do dia; seus efeitos patrimoniais aparecem no saldo informado na manhã seguinte.")
    ),
    card(
      class = "selic-comparison-card",
      fill = FALSE,
      card_header("Carteira × Selic pura"),
      tableOutput("fund_selic_comparison"),
      card_footer("Considera Fundo Selic, BOVA11 e todos os fluxos. Diferença positiva: a carteira rendeu mais que a Selic pura.")
    )
  )
)

server <- function(input, output, session) {
  positions <- reactiveVal(read_positions())
  operations <- reactiveVal(read_operations())
  selic_rate <- reactiveVal({
    x <- read_positions()
    if (nrow(x)) fetch_selic(min(x$data), max(x$data)) else fetch_selic(Sys.Date(), Sys.Date())
  })

  observeEvent(input$refresh_selic, {
    x <- positions()
    req(nrow(x) > 0)
    new_selic <- fetch_selic(min(x$data), max(x$data))
    selic_rate(new_selic)
    if (nrow(new_selic)) {
      showNotification("Selic atualizada.", type = "message")
    } else {
      showNotification("Não foi possível consultar a Selic agora.", type = "warning")
    }
  })

  summary_data <- reactive({
    x <- positions()
    ops <- operations()
    validate(need(nrow(x) > 0, "Informe os primeiros saldos do início do dia."))
    x <- x[order(x$data), , drop = FALSE]
    x$patrimonio <- x$fundo_selic + x$bova11
    initial <- x$patrimonio[1]
    x$fluxo_operacoes <- operation_flows(ops, x$data)
    x$fluxo_liquido <- x$aporte - x$retirada + x$fluxo_operacoes
    x$fluxo_acumulado <- cumsum(x$fluxo_liquido)
    x$fluxo_antes_abertura <- c(0, head(x$fluxo_acumulado, -1))
    x$resultado_liquido <- x$patrimonio - initial - x$fluxo_antes_abertura
    x$rentabilidade_simples <- if (initial > 0) x$resultado_liquido / initial else NA_real_

    selic <- selic_rate()
    base_date <- x$data[1]
    x$selic_acumulada <- vapply(
      x$data,
      function(day) selic_factor(selic, base_date, day) - 1,
      numeric(1)
    )
    x$referencia_selic <- vapply(seq_len(nrow(x)), function(i) {
      target_date <- x$data[i]
      reference <- initial * selic_factor(selic, base_date, target_date)
      if (i > 1) {
        flows <- seq_len(i - 1L)
        factors <- vapply(
          x$data[flows],
          function(flow_date) selic_factor(selic, flow_date, target_date),
          numeric(1)
        )
        reference <- reference + sum(x$fluxo_liquido[flows] * factors)
      }
      reference
    }, numeric(1))
    x
  })

  portfolio_comparison <- reactive({
    x <- summary_data()
    current <- tail(x$patrimonio, 1)
    pure_selic <- tail(x$referencia_selic, 1)
    difference <- current - pure_selic
    difference_pct <- if (pure_selic != 0) difference / pure_selic else NA_real_

    list(
      current = current,
      pure_selic = pure_selic,
      difference = difference,
      difference_pct = difference_pct
    )
  })

  observeEvent(input$open_position, {
    x <- positions()
    latest <- if (nrow(x)) x[which.max(x$data), , drop = FALSE] else empty_positions()
    selic_value <- if (nrow(latest)) latest$fundo_selic else 0
    bova_value <- if (nrow(latest)) latest$bova11 else 0

    showModal(modalDialog(
      title = "Saldos do início do dia",
      p(class = "help-copy", "Informe os saldos observados antes das operações do dia."),
      dateInput("position_date", "Data", value = Sys.Date(), format = "dd/mm/yyyy", language = "pt-BR"),
      numericInput("selic_balance", "Saldo total no Fundo Selic (R$)", value = selic_value, min = 0, step = 0.01),
      numericInput("bova_balance", "Saldo total no BOVA11 (R$)", value = bova_value, min = 0, step = 0.01),
      textInput("position_note", "Observação", placeholder = "Opcional"),
      footer = tagList(
        modalButton("Cancelar"),
        actionButton("save_position", "Salvar saldos iniciais", class = "btn-primary")
      ),
      easyClose = TRUE
    ))
  })

  observeEvent(input$position_date, {
    x <- positions()
    i <- which(x$data == as.Date(input$position_date))
    if (length(i) == 1) {
      updateNumericInput(session, "selic_balance", value = x$fundo_selic[i])
      updateNumericInput(session, "bova_balance", value = x$bova11[i])
      updateTextInput(session, "position_note", value = x$observacao[i])
    } else if (nrow(x) && as.Date(input$position_date) >= min(x$data)) {
      prior <- x[x$data < as.Date(input$position_date), , drop = FALSE]
      row <- prior[which.max(prior$data), , drop = FALSE]
      updateNumericInput(session, "selic_balance", value = row$fundo_selic)
      updateNumericInput(session, "bova_balance", value = row$bova11)
      updateTextInput(session, "position_note", value = "")
    }
  }, ignoreInit = TRUE)

  observeEvent(input$save_position, {
    req(input$position_date)
    vals <- c(input$selic_balance, input$bova_balance)
    validate(need(all(is.finite(vals)) && all(vals >= 0), "Use valores válidos e não negativos."))

    x <- positions()
    existing <- which(x$data == as.Date(input$position_date))
    new_row <- data.frame(
      data = as.Date(input$position_date),
      fundo_selic = input$selic_balance,
      bova11 = input$bova_balance,
      aporte = if (length(existing)) x$aporte[existing[1]] else 0,
      retirada = if (length(existing)) x$retirada[existing[1]] else 0,
      observacao = trimws(input$position_note),
      stringsAsFactors = FALSE
    )
    x <- x[x$data != new_row$data, , drop = FALSE]
    x <- rbind(x, new_row)
    x <- x[order(x$data), , drop = FALSE]

    tryCatch({
      write_csv_safely(x, positions_file)
      positions(x)
      removeModal()
      showNotification("Saldos do início do dia salvos.", type = "message")
    }, error = function(e) showNotification(conditionMessage(e), type = "error"))
  })

  observeEvent(input$operation_date, {
    x <- positions()
    i <- which(x$data == as.Date(input$operation_date))
    updateNumericInput(session, "contribution", value = if (length(i) == 1) x$aporte[i] else 0)
    updateNumericInput(session, "withdrawal", value = if (length(i) == 1) x$retirada[i] else 0)
  })

  observeEvent(input$save_operation, {
    req(input$operation_date, input$selic_operation_type, input$bova_operation_type)
    entries <- data.frame(
      tipo = c(input$selic_operation_type, input$bova_operation_type),
      ativo = c("Fundo Selic", "BOVA11"),
      valor = c(input$selic_operation_value, input$bova_operation_value),
      stringsAsFactors = FALSE
    )
    coherent <- (entries$tipo == "Nenhuma" & entries$valor == 0) |
      (entries$tipo != "Nenhuma" & is.finite(entries$valor) & entries$valor > 0)
    validate(need(all(coherent), "Escolha Compra ou Venda e informe um valor maior que zero."))
    flow_values <- c(input$contribution, input$withdrawal)
    validate(need(all(is.finite(flow_values)) && all(flow_values >= 0), "Use valores válidos e não negativos para aporte e retirada."))
    entries <- entries[entries$tipo != "Nenhuma", , drop = FALSE]
    validate(need(nrow(entries) > 0 || any(flow_values > 0), "Informe ao menos uma operação, aporte ou retirada."))

    daily_positions <- positions()
    position_index <- which(daily_positions$data == as.Date(input$operation_date))
    validate(need(length(position_index) == 1, "Informe primeiro os saldos do início deste dia."))
    daily_positions$aporte[position_index] <- input$contribution
    daily_positions$retirada[position_index] <- input$withdrawal

    x <- operations()
    next_id <- if (nrow(x)) max(x$id, na.rm = TRUE) + 1L else 1L
    if (nrow(entries)) {
      new_row <- data.frame(
        id = seq.int(next_id, length.out = nrow(entries)),
        data = rep(as.Date(input$operation_date), nrow(entries)),
        tipo = entries$tipo,
        ativo = entries$ativo,
        valor = entries$valor,
        observacao = rep(trimws(input$operation_note), nrow(entries)),
        stringsAsFactors = FALSE
      )
      x <- rbind(x, new_row)
      x <- x[order(x$data, x$id), , drop = FALSE]
    }

    tryCatch({
      write_csv_safely(daily_positions, positions_file)
      if (nrow(entries)) write_csv_safely(x, operations_file)
      positions(daily_positions)
      operations(x)
      updateSelectInput(session, "selic_operation_type", selected = "Nenhuma")
      updateNumericInput(session, "selic_operation_value", value = 0)
      updateSelectInput(session, "bova_operation_type", selected = "Nenhuma")
      updateNumericInput(session, "bova_operation_value", value = 0)
      updateTextInput(session, "operation_note", value = "")
      showNotification("Movimentações do fim do dia registradas.", type = "message")
    }, error = function(e) showNotification(conditionMessage(e), type = "error"))
  })

  output$current_total <- renderText(brl(tail(summary_data()$patrimonio, 1)))
  output$net_result <- renderText(brl(tail(summary_data()$resultado_liquido, 1)))
  output$net_return <- renderText(pct(tail(summary_data()$rentabilidade_simples, 1)))
  output$net_contributions <- renderText(brl(tail(summary_data()$fluxo_acumulado, 1)))
  output$accumulated_selic <- renderText(pct(tail(summary_data()$selic_acumulada, 1)))
  output$selic_status <- renderText({
    x <- selic_rate()
    if (!nrow(x)) return("Selic indisponível no momento")
    paste("Última taxa diária:", format(max(x$data), "%d/%m/%Y"))
  })

  output$wealth_plot <- renderEcharts4r({
    x <- summary_data()
    chart_data <- data.frame(
      data = format(x$data, "%d/%m/%Y"),
      carteira = x$patrimonio,
      referencia = x$referencia_selic
    )
    chart_data |>
      e_charts(data) |>
      e_line(
        carteira,
        name = "Carteira",
        symbol_size = 7,
        lineStyle = list(width = 3, color = "#166534"),
        itemStyle = list(color = "#166534")
      ) |>
      e_line(
        referencia,
        name = "Referência Selic",
        symbol_size = 6,
        lineStyle = list(width = 2, type = "dashed", color = "#dc2626"),
        itemStyle = list(color = "#dc2626")
      ) |>
      e_tooltip(trigger = "axis") |>
      e_legend(top = 0, textStyle = list(fontSize = 12)) |>
      e_grid(top = 38, right = 18, bottom = 32, left = 70) |>
      e_y_axis(
        axisLabel = list(
          fontSize = 11,
          formatter = htmlwidgets::JS("function(value){return 'R$ ' + value.toLocaleString('pt-BR', {minimumFractionDigits: 2, maximumFractionDigits: 2});}")
        ),
        scale = TRUE,
        splitLine = list(lineStyle = list(color = "#e2e8f0"))
      ) |>
      e_x_axis(axisLabel = list(fontSize = 11))
  })

  output$composition_plot <- renderEcharts4r({
    x <- tail(summary_data(), 1)
    d <- data.frame(
      ativo = c("Fundo Selic", "BOVA11"),
      valor = c(x$fundo_selic, x$bova11)
    )
    d |>
      e_charts(ativo) |>
      e_bar(
        valor,
        name = "Valor",
        barWidth = "54%",
        itemStyle = list(
          color = htmlwidgets::JS("function(params){return ['#16a34a', '#2563eb'][params.dataIndex];}")
        ),
        label = list(
          show = TRUE,
          position = "top",
          fontSize = 12,
          formatter = htmlwidgets::JS("function(params){return params.value.toLocaleString('pt-BR', {style:'currency', currency:'BRL'});}")
        )
      ) |>
      e_tooltip(
        trigger = "item",
        formatter = htmlwidgets::JS("function(params){return params.name + '<br>' + params.value.toLocaleString('pt-BR', {style:'currency', currency:'BRL'});}")
      ) |>
      e_legend(show = FALSE) |>
      e_grid(top = 30, right = 12, bottom = 25, left = 65) |>
      e_y_axis(
        axisLabel = list(
          fontSize = 11,
          formatter = htmlwidgets::JS("function(value){return 'R$ ' + value.toLocaleString('pt-BR', {minimumFractionDigits: 2, maximumFractionDigits: 2});}")
        ),
        splitLine = list(lineStyle = list(color = "#e2e8f0"))
      ) |>
      e_x_axis(axisLabel = list(fontSize = 11))
  })

  output$positions_table <- renderTable({
    x <- summary_data()
    x <- x[order(x$data, decreasing = TRUE), c("data", "fundo_selic", "bova11", "patrimonio", "aporte", "retirada", "observacao")]
    names(x) <- c("Data", "Fundo Selic", "BOVA11", "Patrimônio", "Aporte no fim do dia", "Retirada no fim do dia", "Observação")
    x$Data <- format(x$Data, "%d/%m/%Y")
    for (j in 2:6) x[[j]] <- brl(x[[j]])
    x
  }, striped = TRUE, hover = TRUE, bordered = FALSE, spacing = "s")

  output$fund_selic_comparison <- renderTable({
    comparison <- portfolio_comparison()
    data.frame(
      Indicador = c(
        "Valor atual da carteira",
        "Se estivesse tudo na Selic pura",
        "A mais / a menos",
        "Diferença percentual"
      ),
      Valor = c(
        brl(comparison$current),
        brl(comparison$pure_selic),
        brl(comparison$difference),
        pct(comparison$difference_pct)
      ),
      check.names = FALSE
    )
  }, striped = FALSE, hover = FALSE, bordered = FALSE, spacing = "s")

  output$operations_table <- renderTable({
    x <- operations()
    if (!nrow(x)) return(data.frame(Mensagem = "Nenhuma operação registrada."))
    x <- x[order(x$data, x$id, decreasing = TRUE), c("data", "tipo", "ativo", "valor", "observacao")]
    names(x) <- c("Data", "Operação", "Ativo", "Valor", "Observação")
    x$Data <- format(x$Data, "%d/%m/%Y")
    x$Valor <- brl(x$Valor)
    x
  }, striped = TRUE, hover = TRUE, bordered = FALSE, spacing = "s")

  output$download_positions <- downloadHandler(
    filename = function() paste0("saldos-diarios-", Sys.Date(), ".csv"),
    content = function(file) write.csv(positions(), file, row.names = FALSE, na = "")
  )
  output$download_operations <- downloadHandler(
    filename = function() paste0("operacoes-", Sys.Date(), ".csv"),
    content = function(file) write.csv(operations(), file, row.names = FALSE, na = "")
  )
}

shinyApp(ui, server)
