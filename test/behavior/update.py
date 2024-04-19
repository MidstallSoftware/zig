#!/usr/bin/env python3
import argparse
import tempfile
import subprocess
import os
import sys
from multiprocessing import Pool
from tqdm import tqdm
import errno
import signal
import functools

SKIP_LINE = 'if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;'
COMMENT = ' // generated by update.py'

ap = argparse.ArgumentParser('script to update passing Zig tests')
ap.add_argument('compiler', type=str, help='Path to Zig compiler')
ap.add_argument('test', type=str, help='Path to file to test')
ap.add_argument('--todo', default=False, action='store_true', help='Print the number of tests that still need to be done')
ap.add_argument('--recheck', default=False, action='store_true', help='Re-check all tests')

args = ap.parse_args()

basedir = os.path.abspath(os.path.dirname(__file__))

# Represents a singular test instance, of some file.
class Test:
    def __init__(
        self,
        test_file,
        # line index of the 'test' statement.
        test_index,
    ):
        self.test_file = test_file
        self.test_index = test_index

        test_line = self.test_file.lines[test_index]

        test_check_index = None
        for i, line in enumerate(self.test_file.lines[test_index + 1:]):
            if line.startswith('test '):
                break
            elif SKIP_LINE in line:
                test_check_index = test_index + i + 1

        assert test_check_index is not None
        test_check = self.test_file.lines[test_check_index]

        if '"' in test_line:
            # Cheekily extract name if we can find it.
            self.name = test_line[len('test "') : -len('" {\n')]
        else:
            self.name = '(unknown)'

        self.test_check_index = test_check_index

        self.execute = True
        self.error = None


# Represents a Zig file with tests
class TestFile:
    pass_count: int

    def __init__(self, path):
        with open(path, 'r') as f:
            test = f.readlines()

        # For every test in the file, insert a SkipZigTest if it doesn't exist yet.
        # This allows re-checking, and saves some compile times in some cases.
        new_test = []
        test_index = None
        last_skip_check = None
        seen_other = False
        for i, line in enumerate(test):
            new_test.append(line)
            if line.startswith('test') or i == len(test) - 1:
                if test_index is not None and not seen_skip:
                    # No skip seen, so insert one
                    if last_skip_check is not None:
                        new_test.insert(last_skip_check, f'    {SKIP_LINE}{COMMENT}\n')
                    else:
                        # Insert an extra newline to make things nice
                        new_test.insert(test_index, '\n')
                        new_test.insert(test_index, f'    {SKIP_LINE}{COMMENT}\n')
                seen_skip = False
                test_index = len(new_test)
                last_skip_check = None
                seen_other = False
            elif SKIP_LINE in line:
                seen_skip = True
            elif line.startswith('    if (builtin.zig_backend ==') and 'return error.SkipZigTest' in line and not seen_other:
                last_skip_check = len(new_test)
            else:
                seen_other = True

        self.path = path
        self.lines = new_test
        self.pass_count = 0


    def get_tests(self):
        tests = []
        for i, line in enumerate(self.lines):
            if line.startswith('test '):
                tests.append(Test(self, i))

        return tests


    def update(self, tests):
        i = 0
        new_test = []
        for line in self.lines:
            if line.startswith('test '):
                test = tests[i]
                i += 1
            elif SKIP_LINE in line and test.error is None:
                continue

            new_test.append(line)

        for i in reversed(range(len(new_test))):
            if new_test[i].startswith('test ') and new_test[i + 1].strip() == '':
                del new_test[i + 1]

        new_test = [line.replace(COMMENT, '') for line in new_test]
        with open(self.path, 'w') as f:
            f.writelines(new_test)

        subprocess.run([args.compiler, 'fmt', self.path], capture_output=True)

def gather_tests():
    test_files = {}
    tests = {}
    if os.path.isfile(args.test):
        test_file = TestFile(args.test)
        tests[args.test] = test_file.get_tests()
        test_files[args.test] = test_file
    else:
        for subdir, dirs, files in os.walk(args.test):
            for path in files:
                path = os.path.join(subdir, path)
                if path.endswith('.zig'):
                    test_file = TestFile(path)
                    tests[path] = test_file.get_tests()
                    test_files[path] = test_file
    return test_files, tests



def run_test(test, tmp_path, tmp_file):
    test_without_check = test.test_file.lines[:]
    del test_without_check[test.test_check_index]

    tmp_file.writelines(test_without_check)
    tmp_file.flush()

    arg = [
        args.compiler,
        'test',
        tmp_path,
        '-target',
        'riscv64-linux',
        '-fno-llvm',
        '-fno-lld',
        '-I../test',
        '--zig-lib-dir',
        '../../lib',
    ]

    try:
        result = subprocess.run(arg, capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        test.error = "timed out"
        return
    
    if result.returncode == 0:
        test.error = None
        return
    else:
        stderr = result.stderr.decode('utf-8')
        if 'panic: reached unreachable code' in stderr:
                error = 'unreachable'
        elif 'panic: index out of bounds' in stderr:
            error = 'index out of bounds'
        elif 'panic: ' in stderr:
            error = 'panic'
        elif 'Segmentation fault' in stderr:
            error = 'segfault'
        elif '... FAIL (' in stderr:
            error = 'test failure'
        elif 'panic: classifySystem Struct' in stderr:
            error = 'uses expectEqualSlices'
        elif result.returncode > 0:
            error = 'return code ' + str(result.returncode)
        
        test.error = error


def process(test):
    file_name = os.path.basename(test.test_file.path)
    tmp = tempfile.NamedTemporaryFile(mode='w', suffix=file_name)
    with tmp as f:
        run_test(test, tmp.name, f)
    return test


test_files, all_tests_by_path = gather_tests()

todo_tests_by_path = {}
all_todo = []
for path, tests in all_tests_by_path.items():
    tests = [test for test in tests if test.execute]
    todo_tests_by_path[path] = len(tests)
    all_todo += tests

if args.todo:
    for k, v in sorted(todo_tests_by_path.items(), key=lambda x: x[1]):
        if v > 0:
            print(v, k)
    print('total:', len(all_todo))
    sys.exit(0)

# tests returned by the pool are deep copies, so we will need to re-order them manually.
new_tests = {}
for path in all_tests_by_path.keys():
    new_tests[path] = all_tests_by_path[path]

total_passed = 0
with Pool() as p:
    for i, test in enumerate(p.imap_unordered(process, all_todo)):
        if test.error is None:
            print(f'[{i + 1}/{len(all_todo)}] \x1b[32mPASS\x1b[0m {test.name}')
            total_passed += 1
        else:
            print(f'[{i + 1}/{len(all_todo)}] \x1b[31mFAIL\x1b[0m {test.name} ({test.error})')

        path = test.test_file.path
        for i in range(len(new_tests[path])):
            if new_tests[path][i].test_index == test.test_index:
                new_tests[path][i] = test

if len(all_todo) == 0:
    print('no tests to execute')
else:
    print(f'{total_passed} passed, {len(all_todo) - total_passed} failed - {total_passed / len(all_todo) * 100:.2f}% passing')

for path, test_file in tqdm(test_files.items()):
    test_file.update(new_tests[path])