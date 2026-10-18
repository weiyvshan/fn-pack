# PowerShell script authoring — common gotchas

Apply when writing `.ps1` in a skill's `scripts/` or `tests/`. These cause real
ParserErrors or silent bugs (a function returning an array instead of a value).
Set-StrictMode + `$ErrorActionPreference = 'Stop'` turn them loud; better to avoid.

## 1. `if` / `switch` cannot be a bare method or cmdlet argument

```powershell
$list.Add(if ($cond) { 0 } else { 1 })   # ParserError: Missing ')' in method call
```

Assign the result first, then pass it:

```powershell
$v = if ($cond) { 0 } else { 1 }
$list.Add($v)
```

Any compound expression used inline as a single argument needs the same treatment.

## 2. Non-void .NET methods leak into the output stream as bare statements

`$sb.Append($x)` and `$sb.AppendLine($x)` **return the StringBuilder**. Used as a
bare statement inside a function, the returned object is emitted to the function's
output stream, so the function returns `[builder, builder, ..., $returnValue]`
(an array) instead of the intended value — under Set-StrictMode this then surfaces
as "property X cannot be found on this object". Silence it:

```powershell
[void]$sb.AppendLine($x)
```

`List<T>.Add` / `Remove` are `void` (safe). String-returning methods (`.Replace`,
`.Trim`) and `ConvertTo-Json` also leak — assign to a variable or `[void]` them.

## 3. Use real .NET member names, not C# aliases

`[Math]::Ceil` fails — .NET's method is `Ceiling`. C# shorthand/alias names do not
exist in PowerShell; call the real .NET member.

## 4. String interpolation with a trailing colon

`"$Name: $Detail"` is parsed as the scope-qualified variable `$Name:` (colon must
be followed by a name) and errors. Brace the variable:

```powershell
"${Name}: $Detail"
```

## Verify after editing

Parse-check a script before running it:

```powershell
$t = $null; $e = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
if ($e) { $e | ForEach-Object { "line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message } }
```
