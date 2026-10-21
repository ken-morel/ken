#!/usr/bin/env nu

# Execute Python code snippet and return stdout or evaluated expression
def main [
    code: string # Python code snippet to execute
] {
    let runner = '
import ast, io, sys
from contextlib import redirect_stdout

code = sys.argv[1]

def exec_with_return(code_str, g, l):
    a = ast.parse(code_str)
    last_expr = None
    if a.body:
        if isinstance(a.body[-1], ast.Expr):
            last_expr = ast.unparse(a.body.pop())
        elif isinstance(a.body[-1], ast.Assign):
            last_expr = ast.unparse(a.body[-1].targets[0])
    exec(ast.unparse(a), g, l)
    if last_expr:
        return eval(last_expr, g, l)

buf = io.StringIO()
with redirect_stdout(buf):
    res = exec_with_return(code, {}, {})
    if res is not None:
        print(res)

out = buf.getvalue()
if out:
    print(out, end="")
'
    let res = (^python3 -c $runner $code | complete)
    if ($res.exit_code == 0) {
        $res.stdout
    } else {
        $"Error executing Python: ($res.stderr)"
    }
}
