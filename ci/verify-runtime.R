#!/usr/bin/env Rscript
expected <- c(
  mfclkit = "44abaaa05692db7ae3e0ec0e52250c51714d1e50",
  mfclshiny = "d76d3cebb3007c633ae64ee8f96cb75632b7d79c",
  FLR4MFCL = "5a29a9b3246bd19dcff350ded7e0e5099145da5e"
)
for (name in names(expected)) {
  observed <- utils::packageDescription(name)$RemoteSha
  if (!identical(observed, unname(expected[[name]]))) {
    stop(name, " does not match the bundled runtime pin")
  }
  cat(name, observed, "\n")
}
