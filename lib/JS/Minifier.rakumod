use v6.d;

unit module JS::Minifier;

my constant %SHORTEN    = 'true' => '!0', 'false' => '!1';

# ECMAScript IdentifierStart: $, _, Unicode letters (Lu Ll Lt Lm Lo), letter
# numbers (Nl), plus '\\' for escaped identifiers.
sub is-id-start(Str $x) returns Bool {
  return False if $x eq '';
  my Int $o = ord($x);
  return True if $o >= 65 && $o <= 90;    # A-Z
  return True if $o >= 97 && $o <= 122;   # a-z
  return True if $o == 0x5F || $o == 0x24 || $o == 0x5C;  # _ $ \
  $o > 126 && (so($x ~~ /<:L>/) || so($x ~~ /<:Nl>/));
}

# ECMAScript IdentifierPart: IdentifierStart + decimal digits (Nd) + combining
# marks (Mn Mc) + connector punctuation (Pc) + ZWNJ/ZWJ format chars. Used for
# the continuation characters of an identifier or number literal.
sub is-alphanum(Str $x) returns Bool {
  return False if $x eq '';
  my Int $o = ord($x);
  return True if $o >= 48 && $o <= 57;    # 0-9 (Nd, fast path)
  return True if is-id-start($x);
  $o > 126 && (
    so($x ~~ /<:Nd>/) || so($x ~~ /<:Mn>/) || so($x ~~ /<:Mc>/) ||
    so($x ~~ /<:Pc>/) || $o == 0x200C || $o == 0x200D   # ZWNJ ZWJ
  );
}

sub is-endspace(Str $x) returns Bool {
  return False if $x eq '';
  my Int $o = ord($x);
  $o == 10 || $o == 13 || $o == 8232 || $o == 8233;
}

sub is-whitespace(Str $x) returns Bool {
  return False if $x eq '';
  my Int $o = ord($x);
  # ECMAScript WhiteSpace and LineTerminator productions
  $o == 0x0009 || $o == 0x000B || $o == 0x000C || $o == 0x0020 ||  # HT VT FF SP
  $o == 0x00A0 || $o == 0x1680 || $o == 0x202F || $o == 0x205F ||  # NBSP OGHAM NNBSP MMSP
  $o == 0x3000 || $o == 0xFEFF ||                                  # IDEOGRAPHIC BOM
  ($o >= 0x2000 && $o <= 0x200A) ||                                # EN QUAD .. HAIR SPACE
  is-endspace($x);
}

sub is-infix(Str $x) returns Bool {
  so $x ne "" && ",;:=&%*<>?|\n".contains: $x;
}

sub is-prefix(Str $x) returns Bool {
  so $x ne "" && ('{([!'.contains($x) || is-infix $x);
}

sub is-postfix(Str $x) returns Bool {
  so $x ne "" && '})]'.contains: $x;
}

# NOTE: 'of' is deliberately *not* in this set: it is the for-of keyword only
# after an identifier in a `for (x of ...)` head, but a plain identifier-
# division in every other position (x = of / 2). regex-can-follow() in
# minify-core resolves that contextually.
my constant $REGEX-START = set <return typeof throw delete void case new in instanceof yield export import extends super await>;
my constant $VAR-LET-CONST = set <var let const>;

sub is-regex-start(Str $w) returns Bool {
  so $w ∈ $REGEX-START;
}

sub on-whitespace-conditional-comment(Str $a, Str $b, Str $c, Str $d) returns Bool {
  is-whitespace($a) && $b eq '/' && ($c eq '/' || $c eq '*') && $d eq '@';
}

my constant $NOCOMPRESS-BEGIN = '/* BEGIN NOCOMPRESS */';
my constant $NOCOMPRESS-END   = '/* END NOCOMPRESS */';
# The block-comment body collected by the state machine has the closing `*/`
# still in the look-ahead window, so the collected text is everything before
# it: the tag minus its trailing two characters.
my constant $NOCOMPRESS-BEGIN-BODY = $NOCOMPRESS-BEGIN.substr(0, *-2);

sub minify-core(:$input!, Str :$copyright = '',
                Bool :$strip_debug = False,
                Bool :$keep_bang_comments = False,
                Bool :$drop_console = False,
                Bool :$drop_debugger = False,
                Bool :$nocompress = False,
                Bool :$aggressive = False) returns Str {

  my Str $input_new = $input ~~ Str ?? $input !! $input.readchars;

  # Normalize CRLF so \r\n is treated as a single newline throughout
  $input_new .= subst("\r\n", "\n", :g);

  my Str $input-text = $input_new;

  unless $input-text.chars {
    return $copyright ?? "/* $copyright */" !! '';
  }

  my Int $len        = $input-text.chars;
  my Int $pos        = 0;
  my @out;
  my Str $last       = '';
  my Str $prevnws    = '';
  my Str $lastnws    = '';
  my Bool $last-was-regex = False;
  # True when the last token consumed was the for-of keyword ('of' directly
  # following an identifier in a `for (x of ...)` head), in which case a
  # following '/' starts a regex literal. Any other 'of' is a plain
  # identifier and '/' after it is division (see regex-can-follow).
  my Bool $last-token-was-forof = False;
  my Int $a-idx = 0;
  my Str $a = ''; my Str $b = ''; my Str $c = ''; my Str $d = '';

  my sub regex-can-follow(Str $w) returns Bool {
    is-regex-start($w)
      || ($w eq 'of' && $last-token-was-forof);
  }

  # Whether the current window position ($a) sits at the start of a line.
  # The index of $a within the input is tracked exactly, so the status is
  # derived from the preceding input character. This is exact even when the
  # state machine consumes characters out of order (delete-chr-b removes a
  # char beyond $a), and it can never misfire on a `;;;` that lives inside a
  # string or template literal, because those are consumed atomically before
  # any of their characters ever reaches $a.
  my sub at-line-start() returns Bool {
    my Int $i = $a-idx - 1;
    while $i >= 0 {
      my Str $c = $input-text.substr($i, 1);
      return True if is-endspace($c);        # a line terminator begins the line
      return False unless is-whitespace($c); # crossing a token means mid-line
      $i--;                                  # skip whitespace-only indentation
    }
    True;                                    # nothing but whitespace before it
  }

  # Whether the run of whitespace beginning at input index $from contains a
  # line terminator. An automatic-semicolon-insertion boundary is a run that
  # ends (at the next non-whitespace token, or EOF) without an endspace;
  # conversely a run containing an endspace terminates the preceding complete
  # statement, allowing it to be removed. $from must be the index of the
  # first character after the statement's token, which $a-idx tracks exactly
  # (the same invariant at-line-start relies on).
  my sub whitespace-run-has-newline(Int $from) returns Bool {
    my Int $i = $from;
    while $i < $len {
      my Str $ch = $input-text.substr($i, 1);
      return True if is-endspace($ch);
      return False unless is-whitespace($ch);
      $i++;
    }
    False;
  }

  my sub get() returns Str {
    return '' if $pos >= $len;
    my Str $ch = $input-text.substr($pos, 1);
    $pos = $pos + 1;
    $ch;
  }

  my sub step-chr-a() {
    if !is-whitespace($a) {
      $prevnws = $lastnws;
      $lastnws = $a;
    }
    $last = $a;
    @out.push($a) if $a;
    $a-idx++;
    $a = $b;
    $b = $c;
    $c = $d;
    $d = get;
  }

  my sub send-chr-out() {
    @out.push($a) if $a;
    $a-idx++;
    $a = $b;
    $b = $c;
    $c = $d;
    $d = get;
  }

  my sub delete-chr-a() {
    $a-idx++;
    $a = $b;
    $b = $c;
    $c = $d;
    $d = get;
  }

  my sub delete-chr-b() {
    $a-idx++;
    $b = $c;
    $c = $d;
    $d = get;
  }

  my sub put-literal() {
    my Str $delimiter = $a;

    if $delimiter eq '`' {
      step-chr-a();
      my Int $brace-depth = 0;
      loop {
        while $a eq '\\' {
          step-chr-a(); step-chr-a();
        }
        if $a eq '`' && $brace-depth == 0 {
          step-chr-a();
          last;
        }
        if $a eq '$' && $b eq '{' && $brace-depth == 0 {
          step-chr-a();
          step-chr-a();
          $brace-depth = 1;
          next;
        }
        if $brace-depth > 0 {
          if !$a {
            die 'unterminated template literal expression, stopped';
          }
          # A '/' followed by '*' or '/' inside the expression is always the
          # start of a comment, never division or a regex literal. The
          # characters are stepped through (not dropped) so the template is
          # preserved verbatim, matching how the rest of the expression is
          # copied; the comment body may legally contain template delimiters
          # such as '`', '}', or '$'+'{', which must not reach the scanners.
          if $a eq '/' && $b eq '*' {
            step-chr-a(); step-chr-a();
            while $a && !($a eq '*' && $b eq '/') {
              step-chr-a();
            }
            die 'unterminated comment, stopped' unless $a;
            step-chr-a(); step-chr-a();
            next;
          }
          if $a eq '/' && $b eq '/' {
            step-chr-a(); step-chr-a();
            while $a && !is-endspace($a) {
              step-chr-a();
            }
            next;
          }
          if $a eq '`' || $a eq "'" || $a eq '"' || ($a eq '/' && is-regex-literal()) {
            put-literal();
            next;
          }
          if $a eq '{' {
            $brace-depth++;
          } elsif $a eq '}' {
            $brace-depth--;
            if $brace-depth == 0 {
              step-chr-a();
              next;
            }
          }
        }
        step-chr-a();
        if !$a && $brace-depth == 0 {
          die 'unterminated template literal, stopped';
        }
      }
      $last-was-regex = False;
      return;
    }

    step-chr-a();

    my Bool $in-class = False;

    loop {
      while $a eq '\\' {
        if is-endspace($b) {
          delete-chr-a();
          delete-chr-a();
          next;
        }
        step-chr-a();
        step-chr-a();
      }
      step-chr-a();
      last if !$a;
      if $delimiter eq '/' {
        if $in-class {
          $in-class = False if $last eq ']';
        }
        elsif $last eq '[' {
          $in-class = True;
        }
      }
      last if $last eq $delimiter && !$in-class;
    }

    $last-was-regex = $delimiter eq '/';

    if $last ne $delimiter {
      die 'unterminated single quoted string literal, stopped' if $delimiter eq "'";
      die 'unterminated double quoted string literal, stopped' if $delimiter eq '"';
      die 'unterminated regular expression literal, stopped';
    }
  }

  my sub collapse-whitespace() {
    while is-whitespace($a) && is-whitespace($b) {
      $a = "\n" if is-endspace($a) || is-endspace($b);
      delete-chr-b();
    }
  }

  my sub skip-whitespace() {
    while is-whitespace($a) {
      delete-chr-a();
    }
  }

  my sub dot-join-safe() returns Bool {
    # A plain decimal integer (e.g. "5") must never be joined directly to a
    # following '.': "5.toString()" is a SyntaxError because the '.' starts a
    # fraction. Numbers that already have a fraction or exponent are
    # unambiguous, so their separator can still be dropped in aggressive mode.
    !($lastnws ~~ /^\d+$/ && $prevnws ne '.');
  }

  my sub preserve-endspace() {
    collapse-whitespace();
    if is-endspace($a) && !is-postfix($b)
        && !($aggressive && $b eq '.' && dot-join-safe()) {
      # In aggressive mode a '.' can only continue an expression, so the
      # separator before it is unnecessary; otherwise keep the newline so
      # automatic-semicolon-insertion semantics are preserved.
      step-chr-a();
    }
    skip-whitespace();
  }

  my sub process-conditional-comment() {
    if on-whitespace-conditional-comment($a, $b, $c, $d) {
      step-chr-a();
    } else {
      preserve-endspace();
    }
  }

  my sub process-double-plus-minus() {
    if is-whitespace($a) {
      if $b eq $last {
        step-chr-a();
      } else {
        preserve-endspace();
      }
    }
  }

  my sub process-property-invocation() {
    if is-whitespace($a) {
      if $b && (is-alphanum($b) || ($b eq '.' && !$aggressive)) {
        # Need a separator before a following identifier/number, or (outside
        # aggressive mode) before a member access; keep a single whitespace char.
        step-chr-a();
      } elsif $b eq '.' {
        if dot-join-safe() {
          # Aggressive mode: a member-access separator is unnecessary.
          skip-whitespace();
        } else {
          # A decimal integer precedes the '.': keep a separator so the
          # output stays valid ("5.toString()" would be a syntax error).
          step-chr-a();
        }
      } else {
        preserve-endspace();
      }
    }
  }

  my sub skip-matching-paren(Str $open, Str $close) {
    my Int $depth = 1;
    $prevnws = $lastnws;
    $lastnws = $open;
    $last = $open;
    while $depth && $a {
      my Str $ch = $a;
      if $ch eq '/' {
        if $b eq '*' {
          while $a && !($a eq '*' && $b eq '/') {
            delete-chr-a();
          }
          die 'unterminated comment, stopped' unless $a;
          delete-chr-a();
          delete-chr-a();
          next;
        }
        if $b eq '/' {
          while $a && !is-endspace($a) {
            delete-chr-a();
          }
          next;
        }
        if is-regex-literal() {
          my $out-start = @out.elems;
          put-literal();
          @out.splice($out-start);
          next;
        }
      }
      if $ch eq "'" || $ch eq '"' || $ch eq '`' {
        my $out-start = @out.elems;
        put-literal();
        @out.splice($out-start);
        next;
      }
      if $ch eq $open  { $depth++; }
      if $ch eq $close { $depth--; }
      if !is-whitespace($ch) {
        $prevnws = $lastnws;
        $lastnws = $ch;
      }
      $last = $ch;
      delete-chr-a();
    }
  }

  # Whether the '/' at $a opens a regular expression literal, as opposed
  # to being a division operator. Mirrors the heuristic used in
  # process-comments. A '/' whose previous non-whitespace char is itself a '/'
  # is a regex unless that slash closed a regex literal (then it is division).
  # A quote/template-literal closer is a division trigger only when the '/'
  # follows on the same line (no endspace crossed since).
  my sub is-regex-literal() returns Bool {
    my Str $ln = $lastnws;
    return True if !$ln;
    if $ln eq '/' {
      return $last-was-regex ?? False !! True;
    }
    return False if ')]}.'.contains($ln);
    # After a string or template literal a '/' is always division: the
    # previous token is an operand, so the parser expects an operator no
    # matter how much whitespace or how many line terminator
    # (automatic-semicolon-insertion does not fire before a '/').
    return False if $ln eq '"' || $ln eq "'" || $ln eq '`';
    return False if is-alphanum($ln) && !regex-can-follow($ln);
    return False if ($ln eq '+' || $ln eq '-') && $prevnws eq $ln;
    return False if $b eq '.' && !regex-can-follow($ln);
    True;
  }

  my sub process-comments() {
    if $b eq '/' {
      my Bool $cc-flag = $c eq '@';

      if $cc-flag {
        repeat {
          send-chr-out();
        } until (!$a || is-endspace($a));

        step-chr-a();
        skip-whitespace();
        return;
      }

      # Discard the remainder of the line.
      repeat {
        delete-chr-a();
      } until (!$a || is-endspace($a));

      if $last && !is-endspace($last) && !is-prefix($last) {
        preserve-endspace();
        return;
      }
      skip-whitespace();
      return;
    }

    if $b eq '*' {
      my Bool $cc-flag = $c eq '@';
      my Bool $bang-flag = $keep_bang_comments && $c eq '!';

      # For IE conditional comments and bang comments: output verbatim
      if $cc-flag || $bang-flag {
        my @buf;
        loop {
          last if !$b || ($a eq '*' && $b eq '/');
          @buf.push($a);
          delete-chr-a();
        }
        die 'unterminated comment, stopped' unless $b;
        if $bang-flag {
          @buf.pop while @buf && is-whitespace(@buf[*-1]);
        }
        @out.push(@buf.join);
        send-chr-out();
        send-chr-out();
        preserve-endspace();
        return;
      }

      # For regular comments: consume and discard
      my @buf;
      loop {
        last if !$b || ($a eq '*' && $b eq '/');
        @buf.push($a) if $nocompress;
        delete-chr-a();
      }

      die 'unterminated comment, stopped' unless $b;

      if $nocompress && @buf.join eq $NOCOMPRESS-BEGIN-BODY {
        # A `/* BEGIN NOCOMPRESS */` marker: copy the source between it and
        # the closing marker into the output verbatim, without minification.
        # The window has advanced two characters past the marker's closing
        # `*/` (buffered in $c and $d), so back the cursor up by two so the
        # raw copy starts at the correct position.
        $pos -= 2;
        my $end = index($input-text, $NOCOMPRESS-END, $pos);
        die 'unterminated NOCOMPRESS block, stopped' unless $end.defined;
        my Str $block = substr($input-text, $pos, $end - $pos);
        my Str $bfirst = $block ?? $block.substr(0, 1) !! '';
        if $bfirst && $last &&
            ((is-alphanum($last) && is-alphanum($bfirst)) ||
             ($last eq '+' && $bfirst eq '+') ||
             ($last eq '-' && $bfirst eq '-')) {
          # The verbatim text and the preceding token would otherwise merge:
          # e.g. `return` + `1` would become the identifier `return1`.
          @out.push(' ');
        }
        @out.push($block);
        $pos = $end + $NOCOMPRESS-END.chars;
        my Int $trail = $block.chars;
        while $trail && is-whitespace($block.substr($trail - 1, 1)) {
          $trail--;
        }
        if $trail {
          my Str $nc = $block.substr($trail - 1, 1);
          $prevnws = $lastnws;
          $lastnws = $nc;
          $last = $nc;
        }
        $a-idx = $pos;
        $a = get; $b = get; $c = get; $d = get;
        preserve-endspace();
        return;
      }

      # Remove the closing * and /
      delete-chr-a();
      $a = ' ';
      collapse-whitespace();

      if ($last && $b &&
          ((is-alphanum($last) && ( is-alphanum($b) || $b eq '.')) ||
           ($last eq '+' && $b eq '+') ||
           ($last eq '-' && $b eq '-') )) {
        if $aggressive && $b eq '.' && dot-join-safe() {
          # Aggressive mode: a member-access separator is unnecessary, so
          # don't leave the placeholder space behind (keeps output stable).
          skip-whitespace();
        } else {
          step-chr-a();
        }
        return;
      }
      if ($last && !is-prefix($last)) {
        preserve-endspace();
        return;
      }
      skip-whitespace();
      return;
    }

    my Str $ln = $lastnws;
    if $ln && (')]}.'.contains($ln) ||
               # After a string/template closer '/' is always division (see
               # is-regex-literal): a line break does not make it a regex.
               ($ln eq '"' || $ln eq "'" || $ln eq '`') ||
               (is-alphanum($ln) && !regex-can-follow($ln)) ||
               (($ln eq '+' || $ln eq '-') && $prevnws eq $ln) ||
               ($ln eq '/' && $last-was-regex)) {
      $last-was-regex = False;
      @out.push(' ') if $last eq '/';
      step-chr-a();
      collapse-whitespace();
      process-conditional-comment();
      return;
    }

    if $ln ne '' && $b eq '.' && !regex-can-follow($ln) {
      $last-was-regex = False;
      @out.push(' ') if $last eq '/';
      collapse-whitespace();
      step-chr-a();
      return;
    }

    @out.push(' ') if $last eq '/';
    put-literal();
    collapse-whitespace();
    process-conditional-comment();
  }

  my sub read-id() returns Str {
    my @id;
    while $a && is-alphanum($a) {
      @id.push($a);
      delete-chr-a();
    }
    @id.join;
  }

  # Snapshot of the mutable minifier state, used by drop_debugger /
  # drop_console to probe how the following stream looks without committing
  # to a decision. Indexes: 0..4 look-ahead window ($pos, $a..$d),
  # 5..8 emitted-token bookkeeping ($prevnws, $lastnws, $last,
  # $last-was-regex), 9 the index of $a within the input (used for the
  # strip_debug line-start check).
  my sub snapshot-state() returns List {
    ($pos, $a, $b, $c, $d, $prevnws, $lastnws, $last, $last-was-regex, $a-idx);
  }

  # Rewind the look-ahead window, emitted-token bookkeeping, and @out to a
  # captured snapshot. Used after a probe that decided NOT to consume: the
  # stream must be left exactly as it was before the probe ran.
  my sub restore-lookahead(@s, Int $out-elems) {
    ($pos, $a, $b, $c, $d, $prevnws, $lastnws, $last, $last-was-regex, $a-idx) = @s;
    @out.splice($out-elems);
  }

  # Restore only the emitted-token bookkeeping, keeping the already-advanced
  # look-ahead window. Used when a statement is genuinely consumed/removed,
  # because the removal leaves trailing-state set as if the statement never
  # emitted any token.
  my sub restore-token-state(@s) {
    ($prevnws, $lastnws, $last, $last-was-regex) = @s[5..8];
  }

  my sub process-char() {
    my Str $ca = $a;
    if $ca eq '/' {
      process-comments();
      return;
    }
    if "'\"`".contains($ca) {
      put-literal();
      preserve-endspace();
      return;
    }
    if $ca eq '+' || $ca eq '-' {
      step-chr-a();
      collapse-whitespace();
      process-double-plus-minus();
      return;
    }
    if $ca eq ';' {
      if $strip_debug && at-line-start() && $b eq ';' && $c eq ';' {
        # A `;;;` debug-prefixed line at the start of a line: discard the
        # rest of the line and the terminating newline. Only reached from a
        # real token boundary (never from inside a string, comment, or
        # template literal, which the state machine consumes atomically).
        while $a && !is-endspace($a) {
          delete-chr-a();
        }
        delete-chr-a() if is-endspace($a);
        skip-whitespace();
        return;
      }
      while is-whitespace($b) {
        delete-chr-b();
      }
      if $b eq '}' {
        delete-chr-a();
        $last = '}';
        return;
      }
      step-chr-a();
      skip-whitespace();
      return;
    }
    if ']})'.contains($ca) {
      step-chr-a();
      preserve-endspace();
      return;
    }
    if is-alphanum($ca) {
      my Str $id = read-id();

      $last-token-was-forof = $id eq 'of' && $lastnws && is-alphanum($lastnws);

      # After a regular-expression literal, an immediately adjacent keyword
      # that begins with a letter (e.g. in / instanceof) would otherwise be
      # consumed as a regex flag, producing invalid output
      # (e.g. "/re/instanceof" -> "Invalid regular expression flags"). Only
      # "in" and "instanceof" can legally follow a regex operand, and both
      # require a space to keep the output valid. The immediate-predecessor
      # check (lastnws eq '/') prevents a stale regex flag from adding a
      # redundant space when the keyword follows something else.
      if $last-was-regex && $lastnws eq '/' && ($id eq 'in' || $id eq 'instanceof') {
        @out.push(' ');
      }

      if $id eq 'debugger' && $drop_debugger {
        my $prev = $lastnws;
        if $prev eq '' || $prev eq ';' || $prev eq '{' || $prev eq '}' {
          # Probe the following stream to decide without mutating the real state.
          my @snap = snapshot-state();
          my $out-elems = @out.elems;
          my $tail-idx = $a-idx;   # first input char after the 'debugger' token
          collapse-whitespace();
          skip-whitespace();
          # 'debugger' is a complete statement, so a line terminator directly
          # after it terminates it via ASI just like a ';' does.
          if $a eq ';' || $a eq '}' || !$a || whitespace-run-has-newline($tail-idx) {
            if $a eq ';' {
              delete-chr-a();
            }
            skip-whitespace();
            return;
          }
          restore-lookahead(@snap, $out-elems);
        }
      }

      if $id eq 'console' && $drop_console {
        # Only drop a standalone "console.method(args)" statement. A console
        # call used as a sub-expression (e.g. "console.log(x).toString()" or
        # "a = console.log(x)") is kept so the output remains valid JS.
        # Probe a clone of the state to decide without mutating the real stream.
        my $prev = $lastnws;
        my Bool $dropit = $prev eq '' || $prev eq ';' || $prev eq '{' || $prev eq '}';
        if $dropit {
          my @snap = snapshot-state();
          my $out-elems = @out.elems;
          collapse-whitespace();
          if $a eq '.' {
            delete-chr-a();                # consume '.'
            collapse-whitespace();
            skip-whitespace();
            my $probe-method = read-id();
            collapse-whitespace();
            skip-whitespace();
            $dropit = so($probe-method.chars && $a eq '(');
            if $dropit {
              delete-chr-a();              # consume '('
              skip-matching-paren('(', ')');
              my $after-call-idx = $a-idx; # first input char after the ')'
              skip-whitespace();
              $dropit = $a eq ';' || $a eq '}' || !$a;
              # ASI: a line terminator directly after the call ends the
              # expression statement, so it can be dropped too — unless the
              # next token continues the expression across the line break
              # (e.g. "console.log(1)\n(function(){})()" calls log's result),
              # which would change semantics. Conservative: any next token
              # that can continue the expression keeps the statement.
              if !$dropit && $a && whitespace-run-has-newline($after-call-idx) {
                if is-alphanum($a) {
                  my $probe-next = read-id();
                  $dropit = $probe-next ne 'in' && $probe-next ne 'instanceof';
                } else {
                  $dropit = !'([`+-*/%&|^<>=?:,.;'.contains($a);
                }
              }
            }
          } else {
            $dropit = False;
          }
          restore-lookahead(@snap, $out-elems);
        }

        if $dropit {
          # The standalone statement is removed entirely, so after consuming
          # it the emitted-token bookkeeping must look as if it never existed.
          my @snap = snapshot-state();
          collapse-whitespace();
          delete-chr-a();                      # consume '.'
          collapse-whitespace();
          skip-whitespace();
          my $method = read-id();
          collapse-whitespace();
          skip-whitespace();
          delete-chr-a();                      # consume '('
          skip-matching-paren('(', ')');
          skip-whitespace();
          if $a eq ';' {
            delete-chr-a();
          }
          skip-whitespace();
          restore-token-state(@snap);
          return;
        }

        # Not a droppable statement — keep the console expression verbatim.
        collapse-whitespace();
        if $a eq '.' {
          delete-chr-a();
          collapse-whitespace();
          skip-whitespace();
          my $method = read-id();
          collapse-whitespace();
          skip-whitespace();
          @out.push('console.' ~ $method);
          $prevnws = $lastnws;
          $lastnws = $method;
          $last = $method.chars ?? $method.substr(*-1, 1) !! '.';
        } else {
          @out.push('console');
          $prevnws = $lastnws;
          $lastnws = 'console';
          $last = 'console';
        }
        collapse-whitespace();
        process-property-invocation();
        return;
      }

      if (%SHORTEN{$id}:exists) {
        if $lastnws ∈ $VAR-LET-CONST || $lastnws eq '.'
            || $a eq ':' || (is-whitespace($a) && $b eq ':')
            || $a eq '(' || $a eq '.' || $a eq '[' {
          @out.push($id);
          $last = $id.substr(*-1, 1);
        } else {
          @out.push(%SHORTEN{$id});
          $last = %SHORTEN{$id}.substr(*-1, 1);
        }
      } else {
        @out.push($id);
        $last = $id.substr(*-1, 1);
      }
      $prevnws = $lastnws;
      $lastnws = $id;
      collapse-whitespace();
      process-property-invocation();
      return;
    }
    step-chr-a();
    skip-whitespace();
  }

  # The `true`/`false` → `!0`/`!1` shortening must never produce the invalid
  # sequence `!0**`/`!1**` (a unary expression immediately before `**` is a
  # SyntaxError). When a shortened literal is followed by a `**` operator,
  # parenthesize it.
  #
  # The scan runs over the final element list. Between the literal and the
  # exponentiation operator white space, preserved block comments
  # (`/*!...*/`, `/*@...*/`, whose closing `*` and `/` are separate elements),
  # and verbatim (NOCOMPRESS) content are transparent; a verbatim
  # (NOCOMPRESS) block may itself open with the `**` operator. Any other
  # element is a real token and stops the search, so parens are added only
  # when the operator truly follows the literal.
  my sub finalize-output() returns Str {
    my sub finalize-scan(Int $i is copy) returns Int {
      loop {
        my Str $el = $i < @out.elems ?? @out[$i] !! '';
        last unless $el;
        if $el.chars == 1 && is-whitespace($el) {
          $i++;
          next;
        }
        if $el.starts-with('/*') {
          $i++;
          $i += 2 unless $el.contains('*/');
          next;
        }
        last;
      }
      $i;
    }

    for 0 ..^ @out.elems -> $i {
      next unless @out[$i] eq '!0' || @out[$i] eq '!1';
      my $j = finalize-scan($i + 1);
      if $j < @out.elems && @out[$j].chars > 1 && @out[$j] ~~ /^ \s* \* \* / {
        @out[$i] = '(' ~ @out[$i] ~ ')';
        next;
      }
      my $k = finalize-scan($j + 1);
      if $j < @out.elems && $k < @out.elems && @out[$j] eq '*' && @out[$k] eq '*' {
        @out[$i] = '(' ~ @out[$i] ~ ')';
      }
    }
    @out.join;
  }

  my Bool $shebang = $len > 1 && $input-text.substr(0, 1) eq '#' && $input-text.substr(1, 1) eq '!';
  if $shebang {
    my $idx = 2;
    my @shebang-line;
    while $idx < $len && !is-endspace($input-text.substr($idx, 1)) {
      @shebang-line.push($input-text.substr($idx, 1));
      $idx++;
    }
    @shebang-line.push("\n") if $idx < $len && is-endspace($input-text.substr($idx, 1));
    @out.push('#!' ~ @shebang-line.join);
    $pos = $idx;
    $pos++ if $idx < $len && is-endspace($input-text.substr($idx, 1));
  }

  # The shebang (if any) must come first in the output; a copyright banner is
  # placed after it, on its own line, so the shebang itself is never broken.
  if $copyright {
    @out.push("\n") if $shebang && @out && @out[*-1].substr(*-1, 1) ne "\n";
    @out.push("/* $copyright */");
  }

  if $pos >= $len {
    return finalize-output();
  }

  $a = get;
  while $a && is-whitespace($a) {
    $a = get;
  }
  $b = get;
  $c = get;
  $d = get;
  $a-idx = 0 max ($pos - 4);

  while $a {
    if is-whitespace($a) {
      die 'minifier bug: minify while loop starting with whitespace, stopped';
    }
    process-char();
  }

  return finalize-output();
}

sub js-minifier(:$input!, Str :$copyright = '', :$channel,
                Bool :$strip_debug = False,
                Bool :$keep_bang_comments = False,
                Bool :$drop_console = False,
                Bool :$drop_debugger = False,
                Bool :$nocompress = False,
                Bool :$aggressive = False) is export {

  my %opts = :$strip_debug, :$keep_bang_comments, :$drop_console,
             :$drop_debugger, :$nocompress, :$aggressive;

  if $channel.defined {
    die "js-minifier: the ':channel' option requires a Channel, got {$channel.^name} instead"
      unless $channel ~~ Channel;
    my $result = try {
      minify-core(:$input, :$copyright, |%opts);
    }
    if $! {
      $channel.close;
      die $!;
    }
    $channel.send($result);
    $channel.close;
    return;
  }

  minify-core(:$input, :$copyright, |%opts);
}

our &js-minify is export = &js-minifier;