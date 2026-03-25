"""
Shader formatting linter for Scanline Classic.

Targets specialized RetroArch shader sources (.slang, .inc) and enforces a
focused style baseline:
- Trailing whitespace is forbidden.
- Tab characters are forbidden (spaces-only indentation/style).
- More than 2 consecutive blank lines is forbidden.
- Control-flow blocks use K&R opening braces: if/else/for/while/switch/do.
- Files must end with a trailing newline.

Notes:
- Function declarations and shader declaration blocks (layout/uniform/struct)
  are intentionally not brace-style enforced because this codebase uses
  shader-specific patterns that differ from strict C-style formatting.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SHADER_DIR = ROOT / "shaders"
SHADER_EXTENSIONS = {".slang", ".inc"}

CONTROL_PATTERN = re.compile(r"^\s*(if|for|while|switch)\b")
ELSE_PATTERN = re.compile(r"^\s*else\b")
DO_PATTERN = re.compile(r"^\s*do\b")
PRAGMA_PARAMETER_PATTERN = re.compile(r"^\s*#pragma\s+parameter\b")
PUSH_LAYOUT_PATTERN = re.compile(r"layout\s*\(\s*push_constant\s*\)\s*uniform\b")
UBO_LAYOUT_PATTERN = re.compile(r"layout\s*\(\s*std140\b[^)]*\)\s*uniform\b")
CONFIG_DEFINE_PATTERN = re.compile(r"^\s*#define\s+\w+\s+config\.(\w+)\b")
GLOBAL_DEFINE_PATTERN = re.compile(r"^\s*#define\s+\w+\s+global\.(\w+)\b")
BLOCK_MEMBER_PATTERN = re.compile(
    r"^\s*(?:layout\s*\([^)]*\)\s*)?"
    r"(?P<type>[A-Za-z_]\w*)\s+"
    r"(?P<name>[A-Za-z_]\w*)"
    r"\s*(?:\[\s*(?P<count>\d+)\s*\])?\s*;"
)
COMMENT_BLOCK_PATTERN = re.compile(r"/\*.*?\*/", re.DOTALL)
STAGE_PATTERN = re.compile(r"^\s*#pragma\s+stage\s+(vertex|fragment)\b")
INCLUDE_PATTERN = re.compile(r'^\s*#include\s+"([^"]+)"')
VARIABLE_DECL_PATTERN = re.compile(
    r"^\s*(?:const\s+)?[A-Za-z_]\w*\s+([A-Za-z_]\w*)\s*(?:\[[^\]]+\])?\s*(?:=[^;]*)?;\s*$"
)


@dataclass(frozen=True)
class LintIssue:
    path: Path
    line: int
    message: str


@dataclass(frozen=True)
class BlockMember:
    line: int
    type_name: str
    name: str
    array_count: int
    conditional: bool


@dataclass(frozen=True)
class UniformBlock:
    start_line: int
    end_line: int
    block_name: str
    instance_name: str
    members: list[BlockMember]


@dataclass(frozen=True)
class UniversalSymbol:
    name: str
    line: int
    kind: str
    definition_text: str


def iter_shader_files(root: Path) -> list[Path]:
    return sorted(
        path for path in root.rglob("*") if path.is_file() and path.suffix.lower() in SHADER_EXTENSIONS
    )


def strip_comments_lines(lines: list[str]) -> list[str]:
    stripped_lines: list[str] = []
    in_block_comment = False

    for line in lines:
        out: list[str] = []
        idx = 0
        while idx < len(line):
            if in_block_comment:
                end = line.find("*/", idx)
                if end == -1:
                    idx = len(line)
                else:
                    in_block_comment = False
                    idx = end + 2
                continue

            if line.startswith("/*", idx):
                in_block_comment = True
                idx += 2
                continue

            if line.startswith("//", idx):
                break

            out.append(line[idx])
            idx += 1

        stripped_lines.append("".join(out))

    return stripped_lines


def has_word(text: str, word: str) -> bool:
    return re.search(rf"\b{re.escape(word)}\b", text) is not None


def collect_universal_symbols(lines: list[str], universal_end_idx: int) -> list[UniversalSymbol]:
    if universal_end_idx <= 0:
        return []

    scoped_lines = strip_comments_lines(lines[:universal_end_idx])
    symbols: list[UniversalSymbol] = []
    seen: set[str] = set()
    depth = 0
    idx = 0

    while idx < len(scoped_lines):
        clean_line = scoped_lines[idx]
        stripped = clean_line.strip()

        if depth == 0 and stripped and not stripped.startswith("#"):
            if "(" in stripped and not stripped.startswith(("if", "for", "while", "switch", "return")):
                sig_end = idx
                sig_lines = [scoped_lines[sig_end]]
                sig_text = " ".join(line.strip() for line in sig_lines)
                while (
                    sig_end + 1 < len(scoped_lines)
                    and ")" not in sig_text
                    and ";" not in sig_text
                    and "#" not in sig_text
                ):
                    sig_end += 1
                    sig_lines.append(scoped_lines[sig_end])
                    sig_text = " ".join(line.strip() for line in sig_lines)

                if ")" in sig_text and not sig_text.lstrip().startswith("#"):
                    prefix = sig_text.split("(", 1)[0].strip()
                    if prefix and "=" not in prefix:
                        parts = prefix.split()
                        name = parts[-1] if parts else ""
                        if re.fullmatch(r"[A-Za-z_]\w*", name) and name not in {"if", "for", "while", "switch"}:
                            start_idx = idx
                            end_idx = sig_end

                            body_start = None
                            for probe in range(start_idx, sig_end + 1):
                                if "{" in scoped_lines[probe]:
                                    body_start = probe
                                    break

                            if body_start is None:
                                nxt = find_next_significant(scoped_lines, sig_end + 1)
                                if nxt and nxt[1].strip() == "{":
                                    body_start = nxt[0]

                            if body_start is not None:
                                end_idx = body_start
                                local_depth = scoped_lines[body_start].count("{") - scoped_lines[body_start].count("}")
                                while local_depth > 0 and end_idx + 1 < len(scoped_lines):
                                    end_idx += 1
                                    local_depth += scoped_lines[end_idx].count("{") - scoped_lines[end_idx].count("}")

                            definition = "\n".join(scoped_lines[start_idx : end_idx + 1])
                            if name not in seen:
                                symbols.append(
                                    UniversalSymbol(name=name, line=start_idx + 1, kind="function", definition_text=definition)
                                )
                                seen.add(name)
                            idx = end_idx + 1
                            depth = 0
                            continue

            if not stripped.startswith(("layout", "struct", "uniform", "in ", "out ", "inout ")):
                var_match = VARIABLE_DECL_PATTERN.match(stripped)
                if var_match:
                    name = var_match.group(1)
                    if name not in seen:
                        symbols.append(
                            UniversalSymbol(name=name, line=idx + 1, kind="variable", definition_text=clean_line)
                        )
                        seen.add(name)

        depth = max(0, depth + clean_line.count("{") - clean_line.count("}"))
        idx += 1

    return symbols


def resolve_shader_include_path(parent_file: Path, include_target: str) -> Path | None:
    include_path = Path(include_target)
    candidates = [
        (parent_file.parent / include_path).resolve(),
        (DEFAULT_SHADER_DIR / include_path).resolve(),
    ]

    for candidate in candidates:
        if candidate.exists() and candidate.is_file() and candidate.suffix.lower() in SHADER_EXTENSIONS:
            return candidate

    return None


def collect_effective_stage_markers(
    path: Path,
    lines: list[str],
    visited_stack: set[Path] | None = None,
) -> list[tuple[Path, int, str]]:
    stack = visited_stack or set()
    if path in stack:
        return []

    stack.add(path)
    markers: list[tuple[Path, int, str]] = []

    for idx, line in enumerate(lines):
        stage_match = STAGE_PATTERN.match(line)
        if stage_match:
            markers.append((path, idx + 1, stage_match.group(1)))

        include_match = INCLUDE_PATTERN.match(line)
        if not include_match:
            continue

        include_target = include_match.group(1)
        include_path = resolve_shader_include_path(path, include_target)
        if include_path is None:
            continue

        include_lines = include_path.read_text(encoding="utf-8").splitlines()
        markers.extend(collect_effective_stage_markers(include_path, include_lines, stack))

    stack.remove(path)
    return markers


def check_shader_stage_flow(path: Path, lines: list[str], issues: list[LintIssue]) -> None:
    stage_markers: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        stage_match = STAGE_PATTERN.match(line)
        if stage_match:
            stage_markers.append((idx + 1, stage_match.group(1)))

    ext = path.suffix.lower()

    if ext == ".inc":
        for line_no, stage in stage_markers:
            issues.append(
                LintIssue(
                    path=path,
                    line=line_no,
                    message=f"Invalid stage declaration in include file: '#pragma stage {stage}' is not allowed in .inc files",
                )
            )
        return

    if ext != ".slang":
        return

    effective_markers = collect_effective_stage_markers(path, lines)
    effective_vertex = [(p, line) for p, line, stage in effective_markers if stage == "vertex"]
    effective_fragment = [(p, line) for p, line, stage in effective_markers if stage == "fragment"]

    if len(effective_vertex) != 1:
        line_hint = effective_vertex[0][1] if effective_vertex and effective_vertex[0][0] == path else 1
        issues.append(
            LintIssue(
                path=path,
                line=line_hint,
                message=(
                    "Shader flow violation: expected exactly 1 vertex shader section "
                    f"after include expansion, found {len(effective_vertex)}"
                ),
            )
        )

    if len(effective_fragment) != 1:
        line_hint = effective_fragment[0][1] if effective_fragment and effective_fragment[0][0] == path else 1
        issues.append(
            LintIssue(
                path=path,
                line=line_hint,
                message=(
                    "Shader flow violation: expected exactly 1 fragment shader section "
                    f"after include expansion, found {len(effective_fragment)}"
                ),
            )
        )

    if len(effective_vertex) != 1 or len(effective_fragment) != 1:
        return

    # Wrapper shaders may intentionally contribute no local stage declarations,
    # relying on included shader files to provide the full stage flow.
    if not stage_markers:
        return

    vertex_lines = [line for line, stage in stage_markers if stage == "vertex"]
    fragment_lines = [line for line, stage in stage_markers if stage == "fragment"]
    if len(vertex_lines) != 1 or len(fragment_lines) != 1:
        return

    vertex_line = vertex_lines[0]
    fragment_line = fragment_lines[0]

    if vertex_line > fragment_line:
        issues.append(
            LintIssue(
                path=path,
                line=vertex_line,
                message="Shader flow violation: vertex shader section must appear before fragment shader section",
            )
        )
        return

    cleaned_lines = strip_comments_lines(lines)
    vertex_text = "\n".join(cleaned_lines[vertex_line: fragment_line - 1])
    fragment_text = "\n".join(cleaned_lines[fragment_line:])

    universal_symbols = collect_universal_symbols(lines, universal_end_idx=vertex_line - 1)
    symbol_by_name = {symbol.name: symbol for symbol in universal_symbols}
    refs: dict[str, set[str]] = {}
    for symbol in universal_symbols:
        dependencies: set[str] = set()
        for candidate_name in symbol_by_name:
            if candidate_name == symbol.name:
                continue
            if has_word(symbol.definition_text, candidate_name):
                dependencies.add(candidate_name)
        refs[symbol.name] = dependencies

    used_in_vertex = {symbol.name for symbol in universal_symbols if has_word(vertex_text, symbol.name)}
    used_in_fragment = {symbol.name for symbol in universal_symbols if has_word(fragment_text, symbol.name)}

    changed = True
    while changed:
        changed = False
        for name in list(used_in_vertex):
            for dep in refs.get(name, set()):
                if dep not in used_in_vertex:
                    used_in_vertex.add(dep)
                    changed = True
        for name in list(used_in_fragment):
            for dep in refs.get(name, set()):
                if dep not in used_in_fragment:
                    used_in_fragment.add(dep)
                    changed = True

    for symbol in universal_symbols:
        in_vertex = symbol.name in used_in_vertex
        in_fragment = symbol.name in used_in_fragment
        if in_vertex and in_fragment:
            continue

        if in_vertex:
            where = "vertex"
        elif in_fragment:
            where = "fragment"
        else:
            where = "neither"

        issues.append(
            LintIssue(
                path=path,
                line=symbol.line,
                message=(
                    "Universal declaration usage violation: "
                    f"{symbol.kind} '{symbol.name}' is used in {where} section only; "
                    "move it to the appropriate shader section unless it is truly shared by both"
                ),
            )
        )


def find_next_significant(lines: list[str], start_index: int) -> tuple[int, str] | None:
    for idx in range(start_index, len(lines)):
        stripped = lines[idx].strip()
        if not stripped:
            continue
        if stripped.startswith("//"):
            continue
        if stripped.startswith("/*"):
            continue
        if stripped.startswith("*"):
            continue
        return idx, lines[idx]
    return None


def leading_indent_segment(line: str) -> str:
    match = re.match(r"^[ \t]+", line)
    return match.group(0) if match else ""


def align_up(value: int, alignment: int) -> int:
    if alignment <= 0:
        return value
    return ((value + alignment - 1) // alignment) * alignment


def base_scalar_size(type_name: str) -> int | None:
    if type_name in {"bool", "int", "uint", "float"}:
        return 4
    if type_name in {"double", "int64_t", "uint64_t", "int64", "uint64"}:
        return 8
    return None


def std430_type_layout(type_name: str) -> tuple[int, int] | None:
    scalar = base_scalar_size(type_name)
    if scalar is not None:
        return scalar, scalar

    vec_match = re.fullmatch(r"([biud]?vec)([2-4])", type_name)
    if vec_match:
        count = int(vec_match.group(2))
        comp_size = 8 if vec_match.group(1).startswith("d") else 4
        if count == 2:
            return 2 * comp_size, 2 * comp_size
        if count == 3:
            return 4 * comp_size, 3 * comp_size
        return 4 * comp_size, 4 * comp_size

    mat_match = re.fullmatch(r"(d?mat)([2-4])(?:x([2-4]))?", type_name)
    if mat_match:
        columns = int(mat_match.group(2))
        rows = int(mat_match.group(3) or mat_match.group(2))
        comp_size = 8 if mat_match.group(1).startswith("d") else 4
        vec_align = 2 * comp_size if rows == 2 else 4 * comp_size
        vec_size = rows * comp_size
        stride = align_up(vec_size, vec_align)
        return vec_align, columns * stride

    return None


def member_layout(type_name: str, array_count: int) -> tuple[int, int] | None:
    base = std430_type_layout(type_name)
    if base is None:
        return None
    base_align, base_size = base
    if array_count <= 1:
        return base_align, base_size
    stride = align_up(base_size, base_align)
    return base_align, array_count * stride


def block_size_bytes(members: list[BlockMember], include_conditional: bool) -> int | None:
    offset = 0
    max_align = 1
    for member in members:
        if member.conditional and not include_conditional:
            continue
        layout = member_layout(member.type_name, member.array_count)
        if layout is None:
            return None
        align, size = layout
        max_align = max(max_align, align)
        offset = align_up(offset, align)
        offset += size
    return align_up(offset, max_align)


def strip_inline_comments(line: str) -> str:
    no_block = COMMENT_BLOCK_PATTERN.sub("", line)
    if "//" in no_block:
        no_block = no_block.split("//", 1)[0]
    return no_block


def parse_uniform_block(lines: list[str], start_idx: int) -> UniformBlock | None:
    start_line = start_idx + 1
    header_line = lines[start_idx]
    block_name_match = re.search(r"uniform\s+(\w+)\b", header_line)
    block_name = block_name_match.group(1) if block_name_match else ""

    idx = start_idx
    while idx < len(lines) and "{" not in lines[idx]:
        idx += 1
    if idx >= len(lines):
        return None

    depth = 0
    in_block = False
    preproc_depth = 0
    members: list[BlockMember] = []
    end_idx = idx
    instance_name = ""

    for line_idx in range(idx, len(lines)):
        line = lines[line_idx]

        if "#if" in line or "#ifdef" in line or "#ifndef" in line:
            if line.strip().startswith("#if") or line.strip().startswith("#ifdef") or line.strip().startswith("#ifndef"):
                preproc_depth += 1
        elif line.strip().startswith("#endif"):
            preproc_depth = max(0, preproc_depth - 1)

        clean = strip_inline_comments(line)
        opens = clean.count("{")
        closes = clean.count("}")

        if opens > 0:
            depth += opens
            in_block = True

        if in_block and depth == 1:
            member_match = BLOCK_MEMBER_PATTERN.match(clean)
            if member_match:
                members.append(
                    BlockMember(
                        line=line_idx + 1,
                        type_name=member_match.group("type"),
                        name=member_match.group("name"),
                        array_count=int(member_match.group("count") or 1),
                        conditional=preproc_depth > 0,
                    )
                )

        if closes > 0:
            depth -= closes
            if in_block and depth <= 0:
                end_idx = line_idx
                tail = clean.split("}", 1)[1]
                instance_match = re.search(r"\b(\w+)\s*;", tail)
                if instance_match:
                    instance_name = instance_match.group(1)
                else:
                    look_ahead = line_idx + 1
                    while look_ahead < len(lines):
                        nxt = strip_inline_comments(lines[look_ahead]).strip()
                        if not nxt:
                            look_ahead += 1
                            continue
                        instance_match = re.search(r"\b(\w+)\s*;", nxt)
                        if instance_match:
                            instance_name = instance_match.group(1)
                        break
                break

    return UniformBlock(
        start_line=start_line,
        end_line=end_idx + 1,
        block_name=block_name,
        instance_name=instance_name,
        members=members,
    )


def pick_members_to_fill_gap(members: list[tuple[str, int]], gap: int) -> tuple[int, list[tuple[str, int]]]:
    if gap <= 0 or not members:
        return 0, []

    dp: list[tuple[int, int] | None] = [None] * (gap + 1)
    dp[0] = (-1, -1)
    for idx, (_, size) in enumerate(members):
        for total in range(gap, size - 1, -1):
            if dp[total] is None and dp[total - size] is not None:
                dp[total] = (total - size, idx)

    best = max((i for i, state in enumerate(dp) if state is not None), default=0)
    chosen: list[tuple[str, int]] = []
    cur = best
    while cur > 0 and dp[cur] is not None:
        prev, member_idx = dp[cur]
        if member_idx < 0:
            break
        chosen.append(members[member_idx])
        cur = prev
    chosen.reverse()
    return best, chosen


def check_block_order_and_push_budget(path: Path, lines: list[str], issues: list[LintIssue]) -> None:
    section_positions: dict[str, int] = {}

    pragma_lines = [idx + 1 for idx, line in enumerate(lines) if PRAGMA_PARAMETER_PATTERN.search(line)]
    if pragma_lines:
        section_positions["parameter_pragmas"] = pragma_lines[0]

    push_idx = next((idx for idx, line in enumerate(lines) if PUSH_LAYOUT_PATTERN.search(line)), None)
    ubo_idx = next((idx for idx, line in enumerate(lines) if UBO_LAYOUT_PATTERN.search(line)), None)
    config_define_lines = [idx + 1 for idx, line in enumerate(lines) if CONFIG_DEFINE_PATTERN.match(line)]
    global_define_matches = [
        (idx + 1, GLOBAL_DEFINE_PATTERN.match(line).group(1))
        for idx, line in enumerate(lines)
        if GLOBAL_DEFINE_PATTERN.match(line)
    ]

    push_block = parse_uniform_block(lines, push_idx) if push_idx is not None else None
    ubo_block = parse_uniform_block(lines, ubo_idx) if ubo_idx is not None else None

    if push_block:
        section_positions["push_block_definition"] = push_block.start_line
    elif push_idx is not None:
        section_positions["push_block_definition"] = push_idx + 1

    if config_define_lines:
        section_positions["push_block_semantic_defines"] = config_define_lines[0]

    if ubo_block:
        section_positions["ubo_definition"] = ubo_block.start_line
    elif ubo_idx is not None:
        section_positions["ubo_definition"] = ubo_idx + 1

    if global_define_matches:
        section_positions["ubo_semantic_defines"] = global_define_matches[0][0]

    ordered_sections = [
        "parameter_pragmas",
        "push_block_definition",
        "push_block_semantic_defines",
        "ubo_definition",
        "ubo_semantic_defines",
    ]

    prev_name: str | None = None
    prev_line: int | None = None
    pretty_names = {
        "parameter_pragmas": "parameter pragmas",
        "push_block_definition": "push block definition",
        "push_block_semantic_defines": "push block semantic defines",
        "ubo_definition": "UBO definition",
        "ubo_semantic_defines": "UBO semantic defines",
    }

    for section in ordered_sections:
        line_no = section_positions.get(section)
        if line_no is None:
            continue
        if prev_line is not None and line_no < prev_line:
            issues.append(
                LintIssue(
                    path=path,
                    line=line_no,
                    message=(
                        "Section order violation: "
                        f"'{pretty_names[section]}' must appear after '{pretty_names[prev_name]}'"
                    ),
                )
            )
        else:
            prev_name = section
            prev_line = line_no

    if not push_block:
        return

    # Evaluate push-constant budget using maximum possible size across
    # conditional compilation paths, while also reporting a minimum bound.
    push_size_min = block_size_bytes(push_block.members, include_conditional=False)
    push_size_max = block_size_bytes(push_block.members, include_conditional=True)

    if push_size_min is None or push_size_max is None:
        issues.append(
            LintIssue(
                path=path,
                line=push_block.start_line,
                message="Unable to compute push block size due to unsupported push-constant type(s)",
            )
        )
        return

    push_limit = 128
    if push_size_max > push_limit:
        issues.append(
            LintIssue(
                path=path,
                line=push_block.start_line,
                message=(
                    "Push block exceeds 128-byte limit: "
                    f"min={push_size_min}B, max={push_size_max}B"
                ),
            )
        )
        return

    if not ubo_block:
        return

    ubo_non_mvp_semantics = [name for _, name in global_define_matches if name != "MVP"]
    if not ubo_non_mvp_semantics:
        for member in ubo_block.members:
            if member.name != "MVP":
                ubo_non_mvp_semantics.append(member.name)

    if push_size_max >= push_limit or not ubo_non_mvp_semantics:
        return

    candidate_members: list[tuple[str, int]] = []
    seen = set()
    for member in ubo_block.members:
        if member.name == "MVP":
            continue
        if member.name in seen:
            continue
        seen.add(member.name)
        layout = member_layout(member.type_name, member.array_count)
        if layout is None:
            continue
        _, size = layout
        candidate_members.append((member.name, size))

    remaining = push_limit - push_size_max
    packed, selected = pick_members_to_fill_gap(candidate_members, remaining)
    target = push_size_max + packed
    if selected:
        move_list = ", ".join(f"{name}({size}B)" for name, size in selected)
        message = (
            "Push block underutilized: "
            f"min={push_size_min}B, max={push_size_max}B (<128B) with non-MVP UBO semantics; "
            f"move candidate(s) from UBO -> push to approach 128B (target {target}B): {move_list}"
        )
    else:
        message = (
            "Push block underutilized: "
            f"min={push_size_min}B, max={push_size_max}B (<128B) with non-MVP UBO semantics; "
            "no fit-to-gap suggestion could be derived from parsed UBO members"
        )

    issues.append(LintIssue(path=path, line=push_block.start_line, message=message))


def check_control_kr_braces(path: Path, lines: list[str], issues: list[LintIssue]) -> None:
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        control_match = CONTROL_PATTERN.match(line)
        is_else = ELSE_PATTERN.match(line) is not None
        is_do = DO_PATTERN.match(line) is not None
        if not control_match and not is_else and not is_do:
            continue

        if "{" in stripped:
            if re.search(r"\S\{", stripped):
                issues.append(
                    LintIssue(
                        path=path,
                        line=idx + 1,
                        message="K&R brace style: expected a space before '{' in control statement",
                    )
                )
            continue

        nxt = find_next_significant(lines, idx + 1)
        if not nxt:
            continue

        next_idx, next_line = nxt
        if next_line.strip() == "{":
            keyword = "else" if is_else else "do" if is_do else control_match.group(1)
            issues.append(
                LintIssue(
                    path=path,
                    line=idx + 1,
                    message=f"K&R brace style: move '{{' onto the same line as '{keyword}'",
                )
            )
            issues.append(
                LintIssue(
                    path=path,
                    line=next_idx + 1,
                    message="Opening brace should not be on a standalone line for control-flow blocks",
                )
            )


def lint_one_file(path: Path, fix: bool, strict_structure: bool) -> tuple[list[LintIssue], bool]:
    raw = path.read_text(encoding="utf-8")
    lines = raw.splitlines()
    issues: list[LintIssue] = []
    changed = False

    fixed_lines: list[str] = []
    blank_run = 0

    for idx, original_line in enumerate(lines):
        line = original_line

        if line.rstrip(" \t") != line:
            issues.append(LintIssue(path=path, line=idx + 1, message="Trailing whitespace"))
            if fix:
                line = line.rstrip(" \t")

        if "\t" in line:
            issues.append(
                LintIssue(
                    path=path,
                    line=idx + 1,
                    message="Tab character found (spaces-only style required)",
                )
            )
            if fix:
                line = line.replace("\t", "    ")

        if line.strip() == "":
            blank_run += 1
            if blank_run > 2:
                issues.append(
                    LintIssue(
                        path=path,
                        line=idx + 1,
                        message="More than 2 consecutive blank lines",
                    )
                )
                if fix:
                    continue
        else:
            blank_run = 0

        fixed_lines.append(line)

    check_control_kr_braces(path, lines, issues)

    if strict_structure:
        check_shader_stage_flow(path, lines, issues)

    if strict_structure and path.suffix.lower() == ".slang":
        check_block_order_and_push_budget(path, lines, issues)

    output_text = "\n".join(fixed_lines)
    if lines:
        output_text += "\n"

    if not raw.endswith("\n"):
        issues.append(LintIssue(path=path, line=max(1, len(lines)), message="Missing trailing newline at end of file"))
        if fix:
            if not output_text.endswith("\n"):
                output_text += "\n"

    if fix and output_text != raw:
        path.write_text(output_text, encoding="utf-8", newline="\n")
        changed = True

    return issues, changed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lint shader formatting in shaders/ (*.slang, *.inc)")
    parser.add_argument(
        "--root",
        type=Path,
        default=DEFAULT_SHADER_DIR,
        help="Shader root directory (default: %(default)s)",
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Apply safe autofixes (tabs to spaces, trailing whitespace, blank-run reduction, EOF newline)",
    )
    parser.add_argument(
        "--strict-structure",
        action="store_true",
        help="Enable stricter shader-structure checks (stage flow, universal declarations, push/UBO ordering/budget)",
    )
    parser.add_argument(
        "--max-errors",
        type=int,
        default=200,
        help="Maximum number of errors to print (default: %(default)s)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()

    if not root.exists() or not root.is_dir():
        print(f"Error: shader root not found or not a directory: {root}", file=sys.stderr)
        return 2

    files = iter_shader_files(root)
    if not files:
        print(f"No shader files found under {root}")
        return 0

    all_issues: list[LintIssue] = []
    changed_files = 0
    for path in files:
        issues, changed = lint_one_file(path, fix=args.fix, strict_structure=args.strict_structure)
        all_issues.extend(issues)
        if changed:
            changed_files += 1

    for issue in all_issues[: args.max_errors]:
        rel = issue.path.relative_to(ROOT)
        print(f"{rel}:{issue.line}: {issue.message}")

    if len(all_issues) > args.max_errors:
        print(f"... {len(all_issues) - args.max_errors} more issue(s) not shown")

    checked_count = len(files)
    if all_issues:
        print(f"\nLint failed: {len(all_issues)} issue(s) across {checked_count} file(s).")
        if args.fix:
            print(f"Autofixed {changed_files} file(s) where safe fixes were possible.")
        return 1

    print(f"Lint passed: checked {checked_count} file(s).")
    if args.fix:
        print(f"Autofixed {changed_files} file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
