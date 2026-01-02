import os
import shutil
import sys
from pathlib import Path
import fnmatch

# Paths
ROOT = Path(__file__).parent
OUT = ROOT / 'out'
OUT_TRIM = ROOT / 'out-trim'
TRIM_RULES_FILE = ROOT / 'trim-rules.txt'

def load_trim_rules(rules_file):
    """Load preset removal rules from a file.
    
    Rules use gitignore-like syntax:
    - Lines starting with # are comments
    - Empty lines are ignored
    - Patterns match preset basenames (without .slangp extension)
    - Wildcards (* and ?) are supported
    """
    if not rules_file.exists():
        print(f"Warning: Trim rules file not found: {rules_file}")
        return []
    
    rules = []
    with open(rules_file, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                rules.append(line)
    return rules

def is_exception(preset_path):
    """Check if a preset is an exception and should never be removed.
    
    Exceptions:
    - sfc* and snes* presets (console examples)
    - aaa-* presets (serve as examples to users)
    """
    basename = preset_path.stem  # filename without extension
    
    # Check exception patterns
    exception_patterns = ['sfc*', 'snes*', 'aaa-*']
    for pattern in exception_patterns:
        if fnmatch.fnmatch(basename, pattern):
            return True
    return False

def should_remove_preset(preset_path, rules):
    """Check if a preset should be removed based on trim rules.
    
    Presets matching exception patterns are never removed.
    """
    # Check exceptions first
    if is_exception(preset_path):
        return False
    
    basename = preset_path.stem  # filename without extension
    
    for rule in rules:
        if fnmatch.fnmatch(basename, rule):
            return True
    return False

def remove_empty_dirs(root_dir, verbose=False):
    """Remove empty directories recursively from bottom up."""
    removed = []
    for dirpath, dirnames, filenames in os.walk(root_dir, topdown=False):
        # Skip the root directory itself
        if Path(dirpath) == root_dir:
            continue
        # Check if directory is empty
        if not os.listdir(dirpath):
            if verbose:
                print(f"  Removing empty directory: {Path(dirpath).relative_to(root_dir)}")
            os.rmdir(dirpath)
            removed.append(dirpath)
    return len(removed)

def copy_and_trim(verbose=False):
    """Copy out to out-trim and apply trimming rules."""
    
    # Remove OUT_TRIM if it exists
    if OUT_TRIM.exists():
        if verbose:
            print(f"Removing existing folder: {OUT_TRIM}")
        shutil.rmtree(OUT_TRIM)
    
    # Copy everything from OUT to OUT_TRIM
    if not OUT.exists():
        print(f"Error: Source folder does not exist: {OUT}")
        print("Please run build.py first.")
        sys.exit(1)
    
    if verbose:
        print(f"Copying {OUT} to {OUT_TRIM}")
    shutil.copytree(OUT, OUT_TRIM)
    
    # Trim doc folder - keep only PARAMETERS.md
    doc_dir = OUT_TRIM / 'doc'
    if doc_dir.exists():
        if verbose:
            print(f"Trimming doc folder: {doc_dir}")
        for item in doc_dir.iterdir():
            if item.name != 'PARAMETERS.md':
                if verbose:
                    print(f"  Removing: {item}")
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()
    
    # Remove *.png from share folder
    share_dir = OUT_TRIM / 'share'
    if share_dir.exists():
        if verbose:
            print(f"Removing PNG files from: {share_dir}")
        for png_file in share_dir.rglob('*.png'):
            if verbose:
                print(f"  Removing: {png_file}")
            png_file.unlink()
    
    # Load trim rules and remove matching presets
    rules = load_trim_rules(TRIM_RULES_FILE)
    if rules:
        if verbose:
            print(f"Loaded {len(rules)} trim rules:")
            for rule in rules:
                print(f"  - {rule}")
        
        presets_dir = OUT_TRIM / 'presets'
        if presets_dir.exists():
            removed_count = 0
            for preset_file in presets_dir.rglob('*.slangp'):
                if should_remove_preset(preset_file, rules):
                    if verbose:
                        print(f"  Removing preset: {preset_file.relative_to(OUT_TRIM)}")
                    preset_file.unlink()
                    removed_count += 1
            
            if verbose or removed_count > 0:
                print(f"Removed {removed_count} preset file(s) based on trim rules")
    else:
        print("No trim rules loaded - no presets will be removed")
    
    # Remove empty directories
    if verbose:
        print("Removing empty directories...")
    empty_dirs_removed = remove_empty_dirs(OUT_TRIM, verbose=verbose)
    if verbose or empty_dirs_removed > 0:
        print(f"Removed {empty_dirs_removed} empty directory(ies)")

def main():
    verbose = '--verbose' in sys.argv
    
    print("Building trimmed distribution...")
    copy_and_trim(verbose=verbose)
    print(f"Trim build complete. Output in '{OUT_TRIM}' folder.")

if __name__ == '__main__':
    main()