rverstring=paste0(R.version$major,".",R.version$minor)

libdir <- paste0("/opt/rstudio/rver/",rverstring)

pnames=c("clustermq", "batchtools", "DBI", "R6", "RJDBC", "RODBC", "RSQLite", "Rcpp", "base64enc", "checkmate", "crayon", "commonmark", "curl", "devtools", "digest", "evaluate", "ellipsis", "fastmap", "glue", "haven", "highr", "htmltools", "htmlwidgets", "httpuv", "jsonlite", "keyring", "knitr", "later", "learnr", "lifecycle", "magrittr", "markdown", "mime", "miniUI", "mongolite", "odbc", "openssl", "packrat", "plumber", "png", "profvis", "promises", "r2d3", "ragg", "rappdirs", "rJava", "readr", "readxl", "renv", "reticulate", "rlang", "rmarkdown", "roxygen2", "rprojroot", "rsconnect", "rstan", "rstudioapi", "shiny", "shinytest", "sourcetools", "stringi", "stringr", "testthat", "tinytex", "withr", "xfun", "xml2", "xtable", "yaml")

avpack<-available.packages()

#Install all packages needed for RSW
for (package in pnames) {
  if (package %in% avpack) {
    install.packages(package,libdir)
  }
}

