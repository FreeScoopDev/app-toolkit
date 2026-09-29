#!/usr/bin/env python3
"""What an app's iCloud (CloudKit) schema must hold for its SwiftData models,
and whether a schema exported from CloudKit Console holds it.

SwiftData syncs through NSPersistentCloudKitContainer, which writes each
@Model object as a record of type CD_<Model>. The fields this check expects:
- CD_<property> for each stored property. Seen in a real Production schema
  (PlowR, 2026-09-29): String and UUID as STRING, Int and Bool as INT64,
  Double as DOUBLE (TimeInterval is Double), Date as TIMESTAMP, and Data and
  arrays of String or Int as BYTES. The rest follow Core Data's attribute
  types, and the output marks them as assumed: other integer types as INT64,
  Float as DOUBLE, URL as STRING, other arrays as BYTES, and a Codable struct
  or enum as one BYTES field (SwiftData may store one differently, so check
  those by hand).
- CD_<property>_ckAsset (ASSET) for each Data property, used once a value too
  large for the record syncs (seen for a photo and a logo);
- CD_<relationship> for each to-one relationship (seen; STRING, holding the
  related record's name, though REFERENCE is accepted too); a to-many
  relationship has no field on its own side;
- CD_entityName (STRING);
- six system fields that every record has, and CloudKit Console counts.

Production can't add a field by itself, and Development only gets a field
when a synced record carries a value for it. So a field can be missing from
Production although no model changed in the release, and until it's deployed
there, a TestFlight or App Store build can't sync a record of that type that
sets it (every record of the type, for a property that's always set). PlowR
1.2.0 had ten fields missing across five record types, and a diff of the
models showed nothing.

The check stops rather than guess. It ends with exit 2, saying where, on any
of these:
- Swift it can't read;
- an @Model that disappears once comments and strings are removed (one
  commented out with /* */ does this too);
- two models with the same name, when neither a top-level typealias
  (typealias Item = SchemaV2.Item) nor a single top-level declaration says
  which one syncs;
- one model inheriting from another.
The ways of writing a model it reads are the ones in the toolkit's self-test.

Usage:
  cloudkit_schema.py <repo>                what every record type needs
  cloudkit_schema.py <repo> <schema.ckdb>  compare with CloudKit Console ->
                                           Production -> Export Schema...
Exit codes: 0 nothing missing; 1 a record type or field is missing or has the
wrong type; 2 usage error, or models this check can't read.
"""
import os
import re
import sys
from dataclasses import dataclass

SYSTEM_FIELDS = 6
SKIP_DIRS = {".git", ".build", "build", "DerivedData", "Pods", "Carthage", "node_modules",
             ".claude", ".swiftpm"}
CONSOLE = {"STRING": "String", "INT64": "Int(64)", "DOUBLE": "Double", "TIMESTAMP": "Date/Time",
           "BYTES": "Bytes", "ASSET": "Asset", "REFERENCE": "Reference", "?": "unknown"}
SCALARS = {
    "String": "STRING", "UUID": "STRING", "URL": "STRING",
    "Bool": "INT64", "Int": "INT64", "Int8": "INT64", "Int16": "INT64", "Int32": "INT64",
    "Int64": "INT64", "UInt": "INT64", "UInt8": "INT64", "UInt16": "INT64", "UInt32": "INT64",
    "UInt64": "INT64", "Double": "DOUBLE", "TimeInterval": "DOUBLE", "Float": "DOUBLE",
    "CGFloat": "DOUBLE", "Date": "TIMESTAMP", "Data": "BYTES",
}
# Types whose field was seen in a real Production schema (PlowR, 2026-09-29).
# A type mismatch on any other is a note, not a failure.
CONFIRMED = {"String", "UUID", "Bool", "Int", "Double", "TimeInterval", "Date", "Data"}
CONFIRMED_ARRAYS = {"String", "Int"}
MODIFIERS = ["public", "private", "fileprivate", "internal", "package", "open", "final",
             "nonisolated", "lazy", "weak", "unowned", "dynamic", "override", "required",
             "convenience"]
CLASS_MODIFIERS = {"public", "internal", "package", "fileprivate", "private", "final", "open",
                   "nonisolated"}
# A statement at the top of a class body that starts with one of these stores
# nothing. Any other statement that mentions var or let stops the check.
NOT_STORED = {"func", "init", "deinit", "subscript", "static", "class", "struct", "enum", "actor",
              "protocol", "typealias", "associatedtype", "extension", "case", "#if", "#elseif",
              "#else", "#endif", "#Unique", "#Index", "#warning", "#error"}
MODIFIER_RE = re.compile(r"(?:(?:%s)\b(?:\s*\(\s*\w+\s*\))?\s*)*" % "|".join(MODIFIERS))
NAME_RE = re.compile(r"\w+")
HEAD_RE = re.compile(r"#?\w+")
STRING_RE = re.compile(r'(#*)("""|")')
REGEX_RE = re.compile(r"(#+)/")
OPEN_LINE_RE = re.compile(r"[ \t]*\n")
MODEL_RE = re.compile(r"@\s*(?:SwiftData\s*\.\s*)?Model\b")
# What doesn't count when @Model is counted in the file as written: // comments,
# and /** */ doc comments that start a line.
UNCOUNTED_RE = re.compile(r"(?ms)^[ \t]*/\*\*.*?\*/|//[^\n]*")
MEMBER_RE = re.compile(r"([\w.]+)\.(now|distantPast|distantFuture|max|min|zero|pi|infinity)")
CLASS_RE = re.compile(r"class\s+(\w+)\s*(?::\s*([^{]*))?\{")
TYPE_DECL_RE = re.compile(r"\b(?:enum|struct|class|actor|extension)\s+(?!func\b|var\b|let\b)([\w.]+)")
TYPEALIAS_RE = re.compile(r"\btypealias\s+(\w+)\s*=\s*([\w.]+)")
BINDING_RE = re.compile(r"`?(\w+)`?\s*(?::\s*(.+?))?\s*(?:=\s*(.*))?$", re.S)


@dataclass
class Field:
    name: str
    ck_type: str
    optional: bool
    kind: str               # "property", "codable", "to-one", "asset" or "entity"
    assumed: bool = False


@dataclass
class Model:
    props: list
    bases: list
    path: str
    enclosing: str


def skip_string(src, i):
    """The index just past the string literal that starts at i: plain,
    multi-line or raw (#"..."#), with interpolations that hold strings."""
    m = STRING_RE.match(src, i)
    hashes, quote = m.group(1), m.group(2)
    j, n = m.end(), len(src)
    if quote == '"""' and hashes:
        # As in Swift's lexer: #"""# is a one-line string holding a quote,
        # because its closing delimiter follows on the same line.
        line_end = src.find("\n", j)
        if src.find('"' + hashes, i + len(hashes) + 2, n if line_end < 0 else line_end) >= 0:
            quote, j = '"', i + len(hashes) + 1
    close, escape = quote + hashes, "\\" + hashes
    while j < n:
        if src.startswith(close, j):
            return j + len(close)
        if src.startswith(escape, j):
            j += len(escape)
            j = skip_parens(src, j) if j < n and src[j] == "(" else j + 1
        elif quote == '"' and src[j] == "\n":
            return j                     # unterminated: it ends with the line
        else:
            j += 1
    return n


def skip_parens(src, i):
    """The index just past the ')' that closes the '(' at i."""
    depth, j, n = 0, i, len(src)
    while j < n:
        if src[j] in '#"' and STRING_RE.match(src, j):
            j = skip_string(src, j)
            continue
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


def regex_end(src, i):
    """The index just past the extended regex literal (#/.../#) at i, or -1.
    It spans lines when #/ ends its line, and a backslash escapes a character."""
    m = REGEX_RE.match(src, i)
    close, j, n = "/" + m.group(1), m.end(), len(src)
    multiline = OPEN_LINE_RE.match(src, j) is not None
    while j < n:
        if src[j] == "\\":
            j += 2
        elif src.startswith(close, j):
            return j + len(close)
        elif src[j] == "\n" and not multiline:
            return -1
        else:
            j += 1
    return -1


def strip_code(src):
    """The source with comments removed and string and extended regex
    literals emptied, so a brace, quote or '//' inside them can't mislead the
    parse."""
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            depth, i = 1, i + 2          # block comments nest in Swift
            while i < n and depth:
                if src.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif src.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
        elif src[i] in '#"' and STRING_RE.match(src, i):
            out.append('""')
            i = skip_string(src, i)
        elif src[i] == "#" and REGEX_RE.match(src, i) and regex_end(src, i) > 0:
            out.append("REGEX")
            i = regex_end(src, i)
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def balanced(src):
    return all(src.count(a) == src.count(b) for a, b in ("{}", "()", "[]"))


def one_line(text):
    return " ".join(text.split())


def skip_attribute(text, i):
    """The index just past the attribute (@Name or @Name(...)) at i, or -1."""
    m = NAME_RE.match(text, i + 1)
    if not text.startswith("@", i) or not m:
        return -1
    j = m.end()
    if j < len(text) and text[j] == "(":
        depth = 0
        for k in range(j, len(text)):
            if text[k] == "(":
                depth += 1
            elif text[k] == ")":
                depth -= 1
                if depth == 0:
                    return k + 1
        return -1
    return j


def type_blocks(src):
    """(start, end, name) for each braced block that a type declaration opens."""
    blocks, stack, last = [], [], 0
    for i, ch in enumerate(src):
        if ch == "{":
            names = TYPE_DECL_RE.findall(src[last:i])
            stack.append((i, names[-1] if names else None))
            last = i + 1
        elif ch == "}":
            if stack:
                start, name = stack.pop()
                if name:
                    blocks.append((start, i, name))
            last = i + 1
        elif ch == ";":
            last = i + 1
    return blocks


def model_classes(src, path, problems):
    """(name, superclass clause, body, enclosing type) for each @Model class
    in stripped source."""
    blocks = type_blocks(src)
    for m in MODEL_RE.finditer(src):
        i, found = m.end(), None
        while i < len(src):
            if src[i].isspace():
                i += 1
            elif src[i] == "@":
                i = skip_attribute(src, i)
                if i < 0:
                    break
            else:
                word = NAME_RE.match(src, i)
                if word and word.group(0) in CLASS_MODIFIERS:
                    i = word.end()
                elif word and word.group(0) == "class":
                    found = CLASS_RE.match(src, i)
                    break
                else:
                    break
        if not found:
            line = src.count("\n", 0, m.start()) + 1
            problems.append(f"{path}:{line}: an @Model this check can't read")
            continue
        start, depth, j = found.end() - 1, 0, found.end() - 1
        while j < len(src):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        inside = [b for b in blocks if b[0] < m.start() < b[1]]
        yield (found.group(1), (found.group(2) or "").strip(), src[start + 1:j],
               base_name(max(inside)[2]) if inside else None)


def top_level_lines(body):
    """The statements at the top of a class body. Anything inside braces is
    reduced to '{}', or to '{observers}' when it holds didSet or willSet, and a
    brace on its own line joins the statement before it. A statement is split
    only outside parentheses and brackets."""
    lines, cur, inner, depth, paren = [], [], [], 0, 0
    for ch in body:
        if ch == "{":
            depth += 1
            if depth == 1:
                inner = []
                continue
        elif ch == "}":
            depth -= 1
            if depth == 0:
                observers = re.search(r"\b(didSet|willSet)\b", "".join(inner))
                marker = "{observers}" if observers else "{}"
                if lines and not "".join(cur).strip():
                    lines[-1] += " " + marker
                else:
                    cur.append(marker)
                continue
        if depth:
            inner.append(ch)
            continue
        if ch in "([":
            paren += 1
        elif ch in ")]":
            paren -= 1
        if ch in "\n;" and paren == 0:
            if "".join(cur).strip():
                lines.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        lines.append("".join(cur).strip())
    return lines


def split_bindings(text):
    """Split 'a = 0, b: Int = 1' into bindings on commas outside brackets and
    generic arguments, or None when those don't balance."""
    parts, cur, depth, angle = [], [], 0, 0
    for i, ch in enumerate(text):
        prev = text[i - 1] if i else ""
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "<" and (prev.isalnum() or prev == "_"):
            angle += 1
        elif ch == ">" and angle and prev != "-":
            angle -= 1
        if ch == "," and not depth and not angle:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return None if depth or angle else [p.strip() for p in parts]


def stored_properties(body, model, problems):
    """(name, declared or inferred type, attributes) for each stored property."""
    props, attrs, seen = [], [], {}
    for line in top_level_lines(body):
        rest = line
        while rest.startswith("@"):
            j = skip_attribute(rest, 0)
            if j < 0:
                problems.append(f"{model}: can't read the attribute in: {one_line(line)}")
                rest = ""
                break
            attrs.append(rest[:j])
            rest = rest[j:].lstrip()
        if not rest:
            continue                     # attributes alone: they belong to the next line
        rest = rest[MODIFIER_RE.match(rest).end():]
        head = HEAD_RE.match(rest)
        word = head.group(0) if head else ""
        if word not in ("var", "let"):
            if word not in NOT_STORED and re.search(r"\b(var|let)\b", rest):
                problems.append(f"{model}: can't read the declaration: {one_line(line)}")
            attrs = []
            continue
        if any(a.startswith("@Transient") or (a.startswith("@Attribute") and ".ephemeral" in a)
               for a in attrs):
            attrs = []                   # tracked but not stored
            continue
        bindings = split_bindings(rest[head.end():])
        if bindings is None:
            problems.append(f"{model}: can't read the declaration: {one_line(line)}")
            bindings = []
        for binding in bindings:
            body_marker = None
            for marker in ("{observers}", "{}"):
                if binding.endswith(marker):
                    body_marker, binding = marker, binding[:-len(marker)].strip()
            m = BINDING_RE.fullmatch(binding)
            if not m or re.search(r"\b(var|let)\s", binding):
                problems.append(f"{model}: can't read the declaration: {one_line(line)}")
                continue
            if body_marker == "{}" and m.group(3) is None:
                continue                 # computed
            name = m.group(1)
            ty = m.group(2).strip() if m.group(2) else inferred_type(m.group(3) or "")
            if name in seen:             # declared again in another #if branch
                if seen[name] != ty:
                    problems.append(f"{model}: {name} is declared twice, with different types")
                continue
            seen[name] = ty
            props.append((name, ty, list(attrs)))
        attrs = []
    return props


def find_models(repo, problems):
    """{model name: stored properties} from the app's Swift sources; test
    targets (a folder ending in Tests) are left out."""
    found, aliases = {}, {}
    for root, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.endswith("Tests"))
        for f in sorted(files):
            if not f.endswith(".swift"):
                continue
            path = os.path.join(root, f)
            with open(path, encoding="utf-8", errors="replace") as fh:
                raw = fh.read()
            src = strip_code(raw)
            rel = os.path.relpath(path, repo)
            for name, target in top_level_aliases(src):
                aliases.setdefault(name, set()).add(target)
            written = len(MODEL_RE.findall(UNCOUNTED_RE.sub("", raw)))
            read = len(MODEL_RE.findall(src))
            if written > read:
                problems.append(f"{rel}: @Model appears {written} times but {read} outside "
                                "comments and strings, so this check misread the file (unless "
                                "one is in a /* */ comment or a string)")
                continue
            if not read:
                continue
            if not balanced(src):
                problems.append(f"{rel}: its brackets don't balance once strings and comments "
                                "are removed, so this check can't read it")
                continue
            for name, superclass, body, enclosing in model_classes(src, rel, problems):
                bases = [base_name(s) for s in superclass.split(",") if s.strip()]
                model = Model(stored_properties(body, name, problems), bases, rel, enclosing)
                found.setdefault(name, []).append(model)
    models = {}
    for name, candidates in sorted(found.items()):
        model = candidates[0] if len(candidates) == 1 else current_version(name, candidates, aliases)
        if model is None:
            where = ", ".join(f"{c.enclosing or 'top level'} in {c.path}" for c in candidates)
            problems.append(f"@Model classes named {name} ({where}): no single top-level "
                            f"typealias {name} = <schema>.{name} says which one syncs")
            continue
        models[name] = model
    for name, model in models.items():
        for base in model.bases:
            if base in models:
                problems.append(f"{name} inherits from the model {base}: this check doesn't "
                                "cover model inheritance; check CloudKit Console by hand")
    return {name: model.props for name, model in models.items()}


def top_level_aliases(src):
    """(name, target) for each typealias outside every type and function body;
    one inside a type is local to it."""
    return [(m.group(1), m.group(2)) for m in TYPEALIAS_RE.finditer(src)
            if src.count("{", 0, m.start()) == src.count("}", 0, m.start())]


def current_version(name, candidates, aliases):
    """Of several @Model classes with one name (schema versions), the one the
    top-level typealiases name, directly or through an alias of its schema;
    else the only one at top level; else None, also when typealiases (in #if
    branches, or in two targets) name different ones."""
    named = []
    for target in aliases.get(name, ()):
        parts = target.split(".")
        if len(parts) < 2 or parts[-1] != name:
            continue
        for schema in {parts[-2]} | aliases.get(parts[-2], set()):
            named += [c for c in candidates if c.enclosing == base_name(schema)]
    if named:
        return named[0] if len({id(c) for c in named}) == 1 else None
    top = [c for c in candidates if c.enclosing is None]
    return top[0] if len(top) == 1 else None


def inferred_type(value):
    """The type Swift infers for a default value written without a type: a
    literal, or an initializer such as Date() or [String](). None otherwise."""
    v = value.strip()
    if v == '""':
        return "String"
    if v in ("true", "false"):
        return "Bool"
    if re.fullmatch(r"-?\d[\d_]*", v):
        return "Int"
    if re.fullmatch(r"-?\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?", v):
        return "Double"
    member = MEMBER_RE.fullmatch(v)
    if member and base_name(member.group(1)) in SCALARS:
        return base_name(member.group(1))
    if re.fullmatch(r"(?:Foundation\.)?UUID\(\)\.uuidString", v):
        return "String"
    call = re.fullmatch(r"([\w.]+|\[[\w.]+\])\(.*\)", v, re.S)
    if call and skip_parens(v, len(call.group(1))) == len(v):    # nothing after the call
        if call.group(1).startswith("["):
            return call.group(1)
        if base_name(call.group(1)) in SCALARS:
            return base_name(call.group(1))
    return None


def base_name(name):
    """A type name without its module or namespace prefix."""
    return name.strip().split(".")[-1]


def unwrap(ty):
    """(type, optional) with Optional<...>, ? and ! removed."""
    t, optional = ty.replace(" ", ""), False
    while True:
        if t.endswith("?") or t.endswith("!"):
            t, optional = t[:-1], True
        elif re.fullmatch(r"Optional<(.+)>", t):
            t, optional = re.fullmatch(r"Optional<(.+)>", t).group(1), True
        else:
            return t, optional


def classify(ty, models):
    """(kind, CloudKit type, optional, assumed) for a declared Swift type;
    kind is "to-many" when the property has no field of its own."""
    t, optional = unwrap(ty)
    array = re.fullmatch(r"\[([\w.]+)\]|(?:Swift\.)?(?:Array|Set)<([\w.]+)>", t)
    if array:
        inner = base_name(array.group(1) or array.group(2))
        if inner in models:
            return "to-many", inner, optional, False
        return "property", "BYTES", optional, inner not in CONFIRMED_ARRAYS
    t = base_name(t) if re.fullmatch(r"[\w.]+", t) else t
    if t in models:
        return "to-one", "STRING", True, False
    if t in SCALARS:
        return "property", SCALARS[t], optional, t not in CONFIRMED
    return "codable", "BYTES", optional, True        # a struct, an enum, a dictionary...


def expected_fields(models):
    """({record type: [Field]}, [many-to-many pairs]) that the models need."""
    out, to_many = {}, {}
    for model, props in models.items():
        fields = [Field("CD_entityName", "STRING", False, "entity")]
        for name, ty, _ in props:
            if ty is None:
                fields.append(Field("CD_" + name, "?", False, "property"))
                continue
            kind, ck_type, optional, assumed = classify(ty, models)
            if kind == "to-many":
                to_many.setdefault(model, set()).add(ck_type)
                continue
            fields.append(Field("CD_" + name, ck_type, optional, kind, assumed))
            if base_name(unwrap(ty)[0]) == "Data":
                fields.append(Field(f"CD_{name}_ckAsset", "ASSET", True, "asset"))
        out["CD_" + model] = sorted(fields, key=lambda f: f.name.lower())
    pairs = sorted({tuple(sorted((a, b))) for a, targets in to_many.items() for b in targets
                    if a in to_many.get(b, ())})
    return dict(sorted(out.items())), pairs


def split_top(text):
    """Split on commas that aren't inside <...> or quotes."""
    parts, cur, angle, quote = [], [], 0, False
    for ch in text:
        if ch == '"':
            quote = not quote
        elif not quote and ch == "<":
            angle += 1
        elif not quote and ch == ">":
            angle -= 1
        if ch == "," and not angle and not quote:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return parts


def parse_schema(text):
    """{record type: {field: type}} from an exported CloudKit schema."""
    text = re.sub(r"//[^\n]*", "", text)
    types = {}
    for m in re.finditer(r'RECORD\s+TYPE\s+"?([\w.]+)"?\s*\(', text):
        i = j = m.end()
        depth = 1
        while j < len(text) and depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        fields = {}
        for item in split_top(text[i:j - 1]):
            item = item.strip()
            if not item or item.upper().startswith("GRANT"):
                continue
            fm = re.match(r'"?([\w.]+)"?\s+(?:ENCRYPTED\s+)?(\w+(?:<[^>]*>)?)', item)
            if fm:
                fields[fm.group(1)] = fm.group(2).upper()
        types[m.group(1)] = fields
    return types


def describe(field):
    notes = []
    if field.kind == "asset":
        notes.append("used once a large value syncs")
    elif field.kind == "to-one":
        notes.append("to-one relationship")
    elif field.optional:
        notes.append("optional")
    if field.kind == "codable":
        notes.append("a Codable value: one field assumed, check by hand")
    elif field.ck_type == "?":
        notes.append("type not inferred, not checked")
    elif field.assumed:
        notes.append("type assumed")
    return f"{field.name:<34} {CONSOLE[field.ck_type]:<10} {', '.join(notes)}".rstrip()


def report_expected(expected):
    print("What the models need in CloudKit. CloudKit Console's field count adds "
          f"{SYSTEM_FIELDS} system fields.")
    for record_type, fields in expected.items():
        print(f"\n{record_type}: {len(fields)} fields, {len(fields) + SYSTEM_FIELDS} in CloudKit Console")
        for f in fields:
            print("  " + describe(f))


def compare(expected, schema):
    """(missing, notes): what the schema lacks, and what's only worth knowing."""
    missing, notes = [], []
    for record_type, fields in expected.items():
        have = schema.get(record_type)
        if have is None:
            missing.append(f"{record_type}: the whole record type, so nothing of this type can sync")
            continue
        for f in fields:
            got = have.get(f.name)
            if got is None:
                if f.kind == "asset":
                    why = "a large value can't sync; add it unless this property always stays small"
                elif f.optional:
                    why = "a record that sets it can't sync"
                else:
                    why = "no record of this type can sync"
                if f.kind == "codable":
                    why += ("; it holds a Codable value, which SwiftData may store differently, "
                            "so check it by hand")
                kind = "the property's type" if f.ck_type == "?" else CONSOLE[f.ck_type]
                missing.append(f"{record_type}: {f.name} ({kind}): {why}")
            elif f.ck_type == "?" or got == f.ck_type or (
                    f.kind == "to-one" and got in ("STRING", "REFERENCE")):
                continue
            elif f.assumed:
                notes.append(f"{record_type}: {f.name} is {got} in the schema; the check assumed "
                             f"{f.ck_type}, so the schema is probably right (update SCALARS)")
            else:
                missing.append(f"{record_type}: {f.name} is {got} in the schema, but the model "
                               f"needs {f.ck_type} ({CONSOLE[f.ck_type]})")
        extra = sorted(n for n in have if n.startswith("CD_") and n not in {f.name for f in fields})
        if extra:
            notes.append(f"{record_type}: in the schema but not in the models (a property removed "
                         f"or renamed; harmless): {', '.join(extra)}")
    for record_type in sorted(schema):
        if record_type.startswith("CD_") and record_type not in expected:
            notes.append(f"{record_type}: no model matches it. A model removed or renamed is "
                         "harmless; one this check didn't find isn't, so check which it is")
    return missing, notes


def many_to_many_note(pairs, schema=None):
    if not pairs:
        return None
    names = ", ".join(f"{a} and {b}" for a, b in pairs)
    note = (f"many-to-many between {names}: SwiftData stores these links as CDMR records, which "
            "this check doesn't cover")
    if schema is not None:
        note += "; the schema has a CDMR record type" if "CDMR" in schema else \
            "; the schema has no CDMR record type, so check the links can sync"
    return note


def main(argv):
    if len(argv) not in (2, 3) or not os.path.isdir(argv[1]):
        print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
        return 2
    problems = []
    models = find_models(argv[1], problems)
    if problems:
        print("Can't check this app's models:", file=sys.stderr)
        for line in problems:
            print("  " + line, file=sys.stderr)
        print("Fix the check for these (lib/cloudkit_schema.py), or compare the record types in "
              "CloudKit Console by hand.", file=sys.stderr)
        return 2
    if not models:
        print(f"No @Model classes found under {argv[1]}", file=sys.stderr)
        return 2
    expected, pairs = expected_fields(models)
    assumed = [f"{rt}.{f.name}" for rt, fs in expected.items() for f in fs if f.assumed]
    unknown = [f"{rt}.{f.name}" for rt, fs in expected.items() for f in fs if f.ck_type == "?"]
    if len(argv) == 2:
        report_expected(expected)
        for line in filter(None, [many_to_many_note(pairs)]):
            print("\nNote: " + line)
        if assumed:
            print(f"\nType assumed, not yet seen in a real schema: {', '.join(assumed)}")
        if unknown:
            print(f"\nType not checked (none written, none inferred): {', '.join(unknown)}")
        return 0
    try:
        with open(argv[2], encoding="utf-8", errors="replace") as fh:
            schema = parse_schema(fh.read())
    except OSError as err:
        print(f"Can't read {argv[2]}: {err}", file=sys.stderr)
        return 2
    if not schema:
        print(f"{argv[2]} has no RECORD TYPE: is it a schema exported from CloudKit Console?",
              file=sys.stderr)
        return 2
    missing, notes = compare(expected, schema)
    notes += list(filter(None, [many_to_many_note(pairs, schema)]))
    if missing:
        print(f"MISSING from {os.path.basename(argv[2])} ({len(missing)}):")
        for line in missing:
            print("  " + line)
        print("\nTo add them: CloudKit Console -> the container -> Development -> Schema -> "
              "Record Types -> open the record type -> add the field with exactly that name and "
              "type -> Save Changes. Then Deploy Schema Changes..., export Production again, and "
              "run this again. (Or run NSPersistentCloudKitContainer.initializeCloudKitSchema() "
              "once from a debug build, which creates every field in Development, then deploy.)")
    else:
        print(f"OK: {os.path.basename(argv[2])} has every field the models need "
              f"({len(expected)} record types).")
    for line in notes:
        print("Note: " + line)
    if assumed:
        print(f"Type assumed, not yet seen in a real schema: {', '.join(assumed)}")
    if unknown:
        print(f"Type not checked (none written, none inferred): {', '.join(unknown)}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
