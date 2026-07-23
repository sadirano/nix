@echo off
REM ---------------------------------------------------------------------------
REM set_vars.cmd - a nix context source, cmd/batch flavour.
REM
REM Place at <project>\.nix\scripts\set_vars.cmd and declare it in
REM <project>\.nix\segments.toml:
REM
REM   [[contexts]]
REM   segment = "task"
REM   run = "set_vars ${task}"
REM   source-template = "/${client_name}/${task}"
REM   cache = "1h"
REM
REM Then `o task:123@project` lands in <project>\acme\123.
REM
REM Contract:
REM   in   arguments from the `run` line; NIX_SEGMENT, NIX_SEGMENT_VALUE,
REM        NIX_ALIAS, NIX_ALIAS_PATH are also set
REM   out  KEY=VALUE lines appended to the file named by %NIX_CONTEXT_OUT%
REM   exit non-zero aborts resolution and nothing is cached
REM
REM stdout is relayed to stderr, so `echo` here is for humans, never for
REM returning values. That is why `@echo off` above is a courtesy, not a
REM requirement - stray output cannot corrupt the variables.
REM ---------------------------------------------------------------------------
setlocal

set "TASK=%~1"
if "%TASK%"=="" (
  echo set_vars: no task id given ^(use `o task:123@%NIX_ALIAS%`^) 1>&2
  exit /b 1
)

echo Looking up ticket %TASK%...

REM --- Replace this block with the real lookup. -------------------------------
REM Anything that can print a value works, for example:
REM   for /f "delims=" %%i in ('curl -s https://tracker/api/ticket/%TASK%/client') do set "CLIENT=%%i"
set "CLIENT=acme"
REM ---------------------------------------------------------------------------

if "%CLIENT%"=="" (
  echo set_vars: ticket %TASK% has no client 1>&2
  exit /b 1
)

REM Redirect FIRST so a trailing space never sneaks into the value.
>>"%NIX_CONTEXT_OUT%" echo client_name=%CLIENT%

exit /b 0
