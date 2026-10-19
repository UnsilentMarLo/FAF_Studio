#!/usr/bin/env python
"""Parallel editor feature development: one git worktree + branch per feature, tested in its own engine instance, merged through an integration worktree.

    python scripts/editor_merge.py new <name> [--base BRANCH]      worktree .claude/worktrees/ed-<name> on branch ed/<name> (from the main checkout's branch) + test instance tag <name>
    python scripts/editor_merge.py status [--base BRANCH]          every ed/* branch: commits ahead / behind, files touched, and which pairs of branches would conflict
    python scripts/editor_merge.py try <name>... [--test]          merge the branches one after the other into a throw-away integration worktree (ed-integrate); lists conflicts;
                                                                   with --test it also runs the self tests of the merged tree in the instance `integrate` (--exe NAME: a private engine build)
    python scripts/editor_merge.py land <name>... [--test]         `try`, then merge the same branches into the base branch of the main checkout (no fast forward, one merge commit each)
    python scripts/editor_merge.py remove <name>                   remove the worktree (the branch stays until it is merged and deleted by hand)

The main checkout is shared with sessions that work without a worktree: `land` refuses when it has uncommitted changes in a file the branches touch (git would refuse too).
See docs/EDITOR_PARALLEL.md.
"""
import argparse
import itertools
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def git(args, cwd=None, check=False):
    r = subprocess.run(['git'] + args, cwd=cwd or main(), capture_output=True, text=True, encoding='utf-8', errors='replace')
    if check and r.returncode != 0:
        raise SystemExit('git %s failed:\n%s%s' % (' '.join(args), r.stdout, r.stderr))
    return r


_MAIN = None


def main():
    """The main checkout (first worktree of the repository)."""
    global _MAIN
    if not _MAIN:
        out = subprocess.run(['git', '-C', ROOT, 'worktree', 'list', '--porcelain'], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if line.startswith('worktree '):
                _MAIN = os.path.normpath(line[len('worktree '):].strip())
                break
    return _MAIN


def wt_path(name):
    return os.path.join(main(), '.claude', 'worktrees', 'ed-' + name)


def base_branch(a):
    if getattr(a, 'base', None):
        return a.base
    return git(['rev-parse', '--abbrev-ref', 'HEAD']).stdout.strip()


def branches():
    out = git(['for-each-ref', '--format=%(refname:short)', 'refs/heads/ed/']).stdout.split()
    return out


def cmd_new(a):
    base = base_branch(a)
    path = wt_path(a.name)
    if os.path.isdir(path):
        raise SystemExit('worktree exists: ' + path)
    git(['worktree', 'add', '-b', 'ed/' + a.name, path, base], check=True)
    print('worktree', path, 'branch ed/' + a.name, 'from', base)
    print('test instance:  python scripts/editor_inst.py new %s --editor "%s" && python scripts/editor_inst.py start %s' % (a.name, os.path.join(path, 'editor', 'runtime'), a.name))


def files_changed(base, br):
    out = git(['diff', '--name-only', '%s...%s' % (base, br)]).stdout.split()
    return set(out)


def cmd_status(a):
    base = base_branch(a)
    bl = branches()
    if not bl:
        print('no ed/* branches')
        return
    info = {}
    for b in bl:
        ahead, behind = git(['rev-list', '--left-right', '--count', '%s...%s' % (base, b)]).stdout.split()
        info[b] = files_changed(base, b)
        print('%-28s ahead %-3s behind %-3s files %d' % (b, behind, ahead, len(info[b])))
    print()
    clean = True
    for x, y in itertools.combinations(bl, 2):
        r = git(['merge-tree', '--write-tree', '--name-only', x, y])
        if r.returncode != 0:
            clean = False
            lines = [l for l in r.stdout.splitlines()[1:] if l.strip() and not l.startswith('Auto-merging') and not l.startswith('CONFLICT')]
            print('CONFLICT %s + %s: %s' % (x, y, ', '.join(lines[:8])))
        else:
            overlap = info[x] & info[y]
            if overlap:
                print('ok (merges, both touch %d file(s): %s)  %s + %s' % (len(overlap), ', '.join(sorted(overlap)[:4]), x, y))
    if clean:
        print('no pair of branches conflicts')


def integrate_tree(base):
    path = wt_path('integrate')
    if os.path.isdir(path):
        git(['worktree', 'remove', '--force', path])
    git(['worktree', 'add', '--detach', path, base], check=True)
    return path


def merge_all(names, base):
    path = integrate_tree(base)
    for n in names:
        br = 'ed/' + n
        r = git(['merge', '--no-ff', '-m', 'merge ' + br, br], cwd=path)
        if r.returncode != 0:
            conflicts = git(['diff', '--name-only', '--diff-filter=U'], cwd=path).stdout.split()
            git(['merge', '--abort'], cwd=path)
            print('CONFLICT while merging %s into the integration tree:' % br)
            for c in conflicts:
                print('   ', c)
            print('resolve it in the branch: merge %s (or the base) into ed/%s, fix, commit, try again' % ('the others', n))
            return None
        print('merged', br)
    return path


def run_tests(path, exe=None):
    inst = os.path.join(HERE, 'editor_inst.py')
    subprocess.run([sys.executable, inst, 'new', 'integrate', '--editor', os.path.join(path, 'editor', 'runtime')], check=True)
    subprocess.run([sys.executable, inst, 'start', 'integrate', '--wait', '120'] + (['--exe', exe] if exe else []), check=True)
    r = subprocess.run([sys.executable, inst, 'selftests', 'integrate', '--keep'], capture_output=True, text=True)
    print(r.stdout)
    subprocess.run([sys.executable, inst, 'stop', 'integrate'])
    return 'FAIL' not in r.stdout.replace('(0 FAIL lines)', '') and r.returncode == 0


def cmd_try(a):
    base = base_branch(a)
    path = merge_all(a.names, base)
    if not path:
        sys.exit(1)
    print('integration tree:', path)
    if a.test and not run_tests(path, getattr(a, 'exe', None)):
        print('SELF TESTS FAILED in the merged tree')
        sys.exit(1)
    print('try: ok')


def cmd_land(a):
    base = base_branch(a)
    path = merge_all(a.names, base)
    if not path:
        sys.exit(1)
    if a.test and not run_tests(path, getattr(a, 'exe', None)):
        print('SELF TESTS FAILED in the merged tree: nothing landed')
        sys.exit(1)
    touched = set()
    for n in a.names:
        touched |= files_changed(base, 'ed/' + n)
    dirty = [l[3:] for l in git(['status', '--porcelain']).stdout.splitlines() if l[3:].replace('\\', '/') in touched]
    if dirty:
        print('the main checkout has uncommitted changes in files the branches touch; commit or park them first:')
        for d in dirty:
            print('   ', d)
        sys.exit(1)
    for n in a.names:
        r = git(['merge', '--no-ff', '-m', 'merge ed/' + n, 'ed/' + n])
        print(r.stdout.strip())
        if r.returncode != 0:
            print(r.stderr.strip())
            git(['merge', '--abort'])
            sys.exit(1)
    git(['worktree', 'remove', '--force', wt_path('integrate')])
    print('landed:', ', '.join(a.names))


def cmd_remove(a):
    r = git(['worktree', 'remove', '--force', wt_path(a.name)])
    print(r.stdout + r.stderr)


class Lock:
    """One try / land at a time: they share the integration worktree and the `integrate` test instance (a second run would delete the first one's tree). A lock older than 30 minutes is stale."""
    def __init__(self):
        self.path = os.path.join(main(), '.claude', 'worktrees', 'ed-integrate.lock')

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        if os.path.exists(self.path) and time.time() - os.path.getmtime(self.path) > 1800:
            os.remove(self.path)
        try:
            fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            raise SystemExit('another try / land is running (lock %s); wait for it, then run this again' % self.path)
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
        return self

    def __exit__(self, *exc):
        try:
            os.remove(self.path)
        except OSError:
            pass


def main_cli():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='c', required=True)
    p = sub.add_parser('new'); p.add_argument('name'); p.add_argument('--base'); p.set_defaults(f=cmd_new)
    p = sub.add_parser('status'); p.add_argument('--base'); p.set_defaults(f=cmd_status)
    p = sub.add_parser('try'); p.add_argument('names', nargs='+'); p.add_argument('--base'); p.add_argument('--test', action='store_true'); p.add_argument('--exe', help='engine exe of the test instance (default main_x64_la_p2.exe), e.g. a private build with new natives'); p.set_defaults(f=cmd_try)
    p = sub.add_parser('land'); p.add_argument('names', nargs='+'); p.add_argument('--base'); p.add_argument('--test', action='store_true'); p.add_argument('--exe', help='engine exe of the test instance, see try'); p.set_defaults(f=cmd_land)
    p = sub.add_parser('remove'); p.add_argument('name'); p.set_defaults(f=cmd_remove)
    a = ap.parse_args()
    if a.c in ('try', 'land'):
        with Lock():
            a.f(a)
    else:
        a.f(a)


if __name__ == '__main__':
    main_cli()
