# JS::Minifier

This is a **fork** of [JS::Minify](https://github.com/scmorrison/JS-Minify) by Sam Morrison.

JS::Minifier removes comments and unnecessary whitespace from JavaScript files. It typically reduces filesize by half, resulting in faster downloads. This is a Raku port of [JSMin](https://github.com/douglascrockford/JSMin) originally created by Douglas Crawford. JS::Minifier incorporates several bug-fixes that have been resolved in various JSMin ports from other languages (Perl, Python, etc.).

JS::Minifier is considered safe:

* Quoted strings and regular expression literals are not modified
* No obfuscation or renaming occurs.

## Additional features over JS::Minify

- CLI tool (`bin/jsminify`) with `--check` and `--output`
- Template literal (backtick) support with `${}` interpolation
- Bang-comment preservation (`/*! ... */` via `--keep-bang-comments`)
- `true`/`false` → `!0`/`!1` shortening (parenthesized when followed by `**`,
  keeping the output valid)
- Semicolon removal before `}`
- Shebang (`#!`) preservation (the shebang is always emitted first, ahead of
  any copyright banner)
- NOCOMPRESS blocks (`/* BEGIN NOCOMPRESS */`)
- `drop_console` / `drop_debugger` options
- Unicode-aware whitespace and identifiers: the full ECMAScript whitespace set
  is collapsed, U+2028 / U+2029 are treated as line terminators (upstream
  JS::Minify recognized only LF, CR, and form feed), and non-ASCII identifier
  characters are respected
- Multi-line string continuation (ECMA-5) stripping
- `--aggressive` option: compacts whitespace while keeping newlines that
  separate statements (ASI-safe)

# Synopsis

Minify a JavaScript file and have the output written directly to another file:

```raku
use JS::Minifier;

my $js = slurp 'myScript.js';
spurt 'myScript.min.js', js-minifier(input => $js);
```

Stream output via client consumer Channel (pass `:channel` to deliver the
minified result on a Channel instead of returning it):

```raku
my $js = slurp 'myScript.js';
my $channel = Channel.new;

js-minifier(input => $js, channel => $channel);

my $out = open "myScript.min.js", :rw;
react {
  whenever $channel -> $chr {
    $out.print($chr);
  }
}
$out.close;
```

Minify a JavaScript string literal:

```raku
my $minified = js-minifier(input => 'var x = 2;');
```

Include a copyright comment at the top of the minified code:

```
js-minifier(input => 'var x = 2;', copyright => 'BSD License');
```

Treat ';;;' as '//' so that debugging code can be removed:

```raku
js-minifier(input => "var x = 2;\n;;;alert('hi');\nvar x = 2;", :strip_debug)
# output: 'var x=2;var x=2;'
```

Drop console and debugger statements:

```raku
js-minifier(input => "console.log('hi');\ndebugger;", :drop_console, :drop_debugger)
# output: ''
```

Preserve important comments:

```raku
js-minifier(input => "var x = 1; /*! license */", :keep_bang_comments)
# output: 'var x=1;/*! license*/'
```

The `input` parameter is mandatory. All other parameters are optional and can be used in any combination.

## Aliases

`js-minify` is also exported as an alias for `js-minifier` for backward compatibility.

# CLI

```
jsminify [options] [file...]
```

If no file is given, reads from stdin. See `jsminify --help` for options.

`--check` runs the minifier over each input as a sanity check: it exits 0 when
everything parses, and 1 otherwise, printing the failure (e.g. an unterminated
string, comment, or NOCOMPRESS block) to stderr. No output is written, so
`--check` cannot be combined with `-o/--output`. It validates that the
minifier itself can process the input; it does not perform a full JavaScript
syntax check.

# Description

This module removes unnecessary whitespace from JavaScript code. The primary requirement developing this module is to not break working code: if working JavaScript is input then working JavaScript is output. It is ok if the input has missing semi-colons, snips like '++ +' or '12 .toString()', for example. Internet Explorer conditional comments are copied to the output but the code inside these comments will not be minified.

The ECMAScript specifications allow for many different whitespace characters: space, horizontal tab, vertical tab, form feed, and line terminators (line feed, carriage return, and the U+2028 / U+2029 separators). This module understands all of these as whitespace and minimizes them. Only U+2028, U+2029, line feed, and carriage return are treated as line terminators, so the newlines that separate statements are still preserved where they affect automatic semicolon insertion. Form feed is treated as ordinary (non-terminating) whitespace.

`;;;` debugging lines are stripped by `strip_debug` when they appear at the
start of a line (a leading whitespace-only indentation does not count against
that, so indented debug lines are stripped too); the same text inside a
string, template literal, or comment is left untouched.

`/* BEGIN NOCOMPRESS */` ... `/* END NOCOMPRESS */` blocks (with `nocompress`)
are copied to the output verbatim. Their content is not minified; note that,
as with the rest of the input, any CRLF line endings are first normalized to
LF, so a block spanning `\r\n` lines comes out with `\n` only. The closing
marker itself is always removed, and anything after it is minified normally.

For static JavaScript files, it is recommended that you minify during the build stage of web deployment. If you minify on-the-fly then it might be a good idea to cache the minified file. Minifying static files on-the-fly repeatedly is wasteful.

## Export

Exported by default: `js-minifier()` (and `js-minify()` as an alias)

# See Also

[JavaScript::Minifier](https://metacpan.org/pod/JavaScript::Minifier) (Perl)

# Repository

You can obtain the latest source code and submit bug reports on the repository for this module:
[https://git.disroot.org/sasha/JS-Minifier](https://git.disroot.org/sasha/JS-Minifier).

# Author

* Sasha Abbott, [sasha](https://git.disroot.org/sasha), &lt;sashaa@disroot.org&gt;, auth `zef:sasha`

## JS::Minifier is based on JS::Minify by:

* Sam Morrison, [scmorrison](https://github.com/scmorrison/)

## JS::Minify was based on the Perl *Javascript::Minifier* module developed by:

* Zoffix Znet, <zoffix@cpan.org> [https://metacpan.org/author/ZOFFIX](https://metacpan.org/author/ZOFFIX)
* Peter Michaux, <petermichaux@gmail.com>
* Eric Herrera, <herrera@10east.com>
* Miller 'tmhall' Hall
* Вячеслав 'vti' Тихановский

The original JSMin was developed by Douglas Crockford:

* [JSMin](https://github.com/douglascrockford/JSMin)

# License Information

"JS::Minifier" is free software; you can redistribute it and/or modify it under the terms of the Artistic License 2.0. (Note that, unlike the Artistic License 1.0, version 2.0 is GPL compatible by itself, hence there is no benefit to having an Artistic 2.0 / GPL disjunction.) See the file LICENSE for details.
