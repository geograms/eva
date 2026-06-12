"""Transpile a model into a loadable Cactus bundle (config + weights + components/).

The on-device engine cannot transpile; it only loads an already-transpiled
bundle. This runs the host-side transpiler (download CQ weights -> transpile)
and prints the resulting bundle directory.

Usage: python transpile_model.py <model_id> <output_dir> [bits]
"""
import sys

from cactus.cli.model import ensure_bundle, TranspileOptions


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    model_id = sys.argv[1]
    output_dir = sys.argv[2]
    bits = int(sys.argv[3]) if len(sys.argv) > 3 else 4

    bundle = ensure_bundle(
        model_id,
        bits=bits,
        output_dir=output_dir,
        transpile=TranspileOptions(),
    )
    print(f"BUNDLE: {bundle}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
