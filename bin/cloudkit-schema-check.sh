#!/usr/bin/env bash
#
# What an app's CloudKit schema must hold for its SwiftData models, and
# whether a schema exported from CloudKit Console holds it.
#
#   cloudkit-schema-check.sh <repo>                what every record type needs
#   cloudkit-schema-check.sh <repo> <schema.ckdb>  compare with Production's
#                                                   export (Export Schema...)
#
# Exit 0 nothing missing, 1 something missing or mistyped, 2 usage error or
# models it can't read (it says where).
# The rule it applies, and why a release needs it: lib/cloudkit_schema.py.
set -euo pipefail
TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$TOOLKIT/lib/cloudkit_schema.py" "$@"
