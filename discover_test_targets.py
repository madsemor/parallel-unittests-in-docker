import re
import sys
from pathlib import Path


def _collect_annotations(lines, method_index):
    annotations = []
    cursor = method_index - 1
    while cursor >= 0:
        stripped = lines[cursor].strip()
        if not stripped:
            break
        if stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*") or stripped.startswith("*/"):
            cursor -= 1
            continue
        if stripped.startswith("@") or stripped.startswith("{") or stripped.startswith("}") or stripped.startswith(")") or stripped.startswith(",") or stripped.startswith('"'):
            annotations.append(stripped)
            cursor -= 1
            continue
        break

    return "\n".join(reversed(annotations))


def _count_csv_source_invocations(annotation_text):
    if "@CsvSource" not in annotation_text:
        return 1

    source_block = annotation_text.split("@CsvSource", 1)[1]
    if "{" in source_block and "}" in source_block:
        source_block = source_block.split("{", 1)[1].split("}", 1)[0]

    values = re.findall(r'"[^"]*"', source_block)
    return len(values) if values else 1


def _count_value_source_invocations(annotation_text):
    if "@ValueSource" not in annotation_text:
        return 1

    source_block = annotation_text.split("@ValueSource", 1)[1]
    if "{" in source_block and "}" in source_block:
        source_block = source_block.split("{", 1)[1].split("}", 1)[0]

    values = re.findall(r'"[^"]*"|[-+]?\d+', source_block)
    return len(values) if values else 1


def discover_test_targets(path, test_root=None):
    path = Path(path).resolve()
    if test_root is None:
        for ancestor in [path] + list(path.parents):
            candidate = ancestor / "src" / "test" / "java"
            if candidate.exists():
                test_root = candidate
                break
        if test_root is None:
            raise ValueError(f"Unable to find src/test/java under {path}")
    else:
        test_root = Path(test_root).resolve()

    rel = path.relative_to(test_root)
    class_name = ".".join(rel.with_suffix("").parts)

    lines = path.read_text(encoding="utf-8").splitlines()
    targets = []
    for index, line in enumerate(lines):
        match = re.match(
            r'^\s*(?:public|protected|private)?\s*(?:static\s+)?(?:final\s+)?(?:[\w<>\[\],?]+\s+)+(\w+)\s*\(',
            line,
        )
        if not match:
            continue

        method_name = match.group(1)
        annotation_text = _collect_annotations(lines, index)

        if "@Test" not in annotation_text and "@ParameterizedTest" not in annotation_text:
            continue

        if "@ParameterizedTest" in annotation_text and "@CsvSource" in annotation_text:
            invocation_count = _count_csv_source_invocations(annotation_text)
        elif "@ParameterizedTest" in annotation_text and "@ValueSource" in annotation_text:
            invocation_count = _count_value_source_invocations(annotation_text)
        else:
            invocation_count = 1

        full_name = f"{class_name}#{method_name}"
        for invocation in range(1, invocation_count + 1):
            if invocation_count > 1:
                targets.append(f"{full_name}[{invocation}]")
            else:
                targets.append(full_name)

    return targets


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 discover_test_targets.py <root> [--filter-class <class_pattern>]", file=sys.stderr)
        sys.exit(2)

    root = Path(sys.argv[1]).resolve()
    test_root = root / "src" / "test" / "java"
    
    # Parse optional filter argument
    filter_class = None
    if len(sys.argv) > 2 and sys.argv[2] == "--filter-class":
        if len(sys.argv) > 3:
            filter_class = sys.argv[3]

    for path in sorted(test_root.rglob("*Test.java")):
        for target in discover_test_targets(path, test_root):
            # If filter is specified, only include targets that match
            if filter_class:
                if filter_class in target:
                    print(target)
            else:
                print(target)



if __name__ == "__main__":
    sys.exit(main())
