# Coefficient resources

Shared source of truth for both the Swift app and `tools/prototype.py`. Keep
them in sync. The Python oracle is the golden-file fixture the Swift ingestor
is tested against, and both read *these* files, so a coefficient change lands in
both at once.

- **`energy-model.json`**: per-tier Wh/1k-token coefficients with `lo`/`v`/`hi`
  bands, plus the cache read/write factors, caveats, equivalences, and grid
  defaults. Every number carries a basis, a confidence, and source URLs.
- **`pricing.json`**: published Anthropic per-MTok rates and cache multipliers.
  Unlike the energy figures, these are exact.

Two rules when editing:

1. **Never add a bare number.** If you can't state where a coefficient came from
   and how confident it is, it doesn't belong here.
2. **Never silently drop an unrecognized model.** A model without coefficients
   must surface as a loud error, not as zero energy. Silent zeroing is the
   failure mode that makes a tool like this quietly wrong.
