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
  $o == 10 || $o == 12 || $o == 13 || $o == 8232 || $o == 8233;
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

my constant $REGEX-START = set <return typeof throw delete void case new in instanceof yield export import extends super await>;
my constant $VAR-LET-CONST = set <var let const>;

sub is-regex-start(Str $w) returns Bool {
  so $w ∈ $REGEX-START;
}

sub on-whitespace-conditional-comment(Str $a, Str $b, Str $c, Str $d) returns Bool {
  is-whitespace($a) && $b eq '/' && ($c eq '/' || $c eq '*') && $d eq '@';
}

# Replace the NUL-delimited NOCOMPRESS placeholder keys with their raw-block
# values in a single pass. Uses a single scan of the output (O(output)),
# independent of the number of blocks (the previous per-block :g subst was
# O(blocks x output)). The placeholder format \x00N<idx>N\x00 cannot collide
# with NUL-free JS source.
sub restore-nocompress(Str $result, @nocompress_blocks) returns Str {
  return $result unless @nocompress_blocks;
  my %map = @nocompress_blocks.map(-> [$key, $block] { $key => $block });
  $result.subst(/ "\x00N" (\d+) "N\x00" /, -> $/ {
    %map{"\x00N" ~ $0 ~ "N\x00"} // ~$/
  } , :g);
}

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
  my @nocompress_blocks;

  if $strip_debug {
    $input-text = $input-text.subst(/ [ ^ | <?after \n> ] \s* ";;;" <-[\n]>* \n? /, '', :g);
  }

  if $nocompress {
    constant $BEGIN_TAG = '/* BEGIN NOCOMPRESS */';
    constant $END_TAG   = '/* END NOCOMPRESS */';
    my Str @processed;
    my $pos = 0;
    my $idx = 0;
    loop {
      my $begin = index($input-text, $BEGIN_TAG, $pos);
      last unless $begin.defined;
      @processed.push(substr($input-text, $pos, $begin - $pos));
      my $end = index($input-text, $END_TAG, $begin);
      die 'unterminated NOCOMPRESS block, stopped' unless $end.defined;
      my $block = substr($input-text, $begin + $BEGIN_TAG.chars, $end - $begin - $BEGIN_TAG.chars);
      my $key = "\x00N" ~ $idx ~ "N\x00";
      @nocompress_blocks.push([$key, $block]);
      @processed.push($key);
      $pos = $end + $END_TAG.chars;
      $idx++;
    }
    @processed.push(substr($input-text, $pos));
    $input-text = @processed.join;
  }

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
  my Str $a = ''; my Str $b = ''; my Str $c = ''; my Str $d = '';

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
    $a = $b;
    $b = $c;
    $c = $d;
    $d = get;
  }

  my sub send-chr-out() {
    @out.push($a) if $a;
    $a = $b;
    $b = $c;
    $c = $d;
    $d = get;
  }

  my sub delete-chr-a() {
    $a = $b;
    $b = $c;
    $c = $d;
    $d = get;
  }

  my sub delete-chr-b() {
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
      last if $last eq $delimiter || !$a;
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
    if $ln eq '"' || $ln eq "'" || $ln eq '`' {
      return is-endspace($last) ?? True !! False;
    }
    return False if is-alphanum($ln) && !is-regex-start($ln);
    return False if ($ln eq '+' || $ln eq '-') && $prevnws eq $ln;
    return False if $b eq '.' && !is-regex-start($ln);
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
      loop {
        last if !$b || ($a eq '*' && $b eq '/');
        delete-chr-a();
      }

      die 'unterminated comment, stopped' unless $b;

      # Remove the closing * and /
      delete-chr-a();
      $a = ' ';
      collapse-whitespace();

      if ($last && $b &&
          ((is-alphanum($last) && ( is-alphanum($b) || $b eq '.')) ||
           ($last eq '+' && $b eq '+') ||
           ($last eq '-' && $b eq '-') )) {
        step-chr-a();
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
               (($ln eq '"' || $ln eq "'" || $ln eq '`') && !is-endspace($last)) ||
               (is-alphanum($ln) && !is-regex-start($ln)) ||
               (($ln eq '+' || $ln eq '-') && $prevnws eq $ln) ||
               ($ln eq '/' && $last-was-regex)) {
      $last-was-regex = False;
      @out.push(' ') if $last eq '/';
      step-chr-a();
      collapse-whitespace();
      process-conditional-comment();
      return;
    }

    if $ln ne '' && $b eq '.' && !is-regex-start($ln) {
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
  # $last-was-regex).
  my sub snapshot-state() returns List {
    ($pos, $a, $b, $c, $d, $prevnws, $lastnws, $last, $last-was-regex);
  }

  # Rewind the look-ahead window, emitted-token bookkeeping, and @out to a
  # captured snapshot. Used after a probe that decided NOT to consume: the
  # stream must be left exactly as it was before the probe ran.
  my sub restore-lookahead(@s, Int $out-elems) {
    ($pos, $a, $b, $c, $d, $prevnws, $lastnws, $last, $last-was-regex) = @s;
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
          collapse-whitespace();
          skip-whitespace();
          if $a eq ';' || $a eq '}' || !$a {
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
              skip-whitespace();
              $dropit = $a eq ';' || $a eq '}' || !$a;
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

  if $copyright {
    @out.push("/* $copyright */");
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
    if $pos >= $len {
      return restore-nocompress(@out.join, @nocompress_blocks);
    }
  }

  $a = get;
  while $a && is-whitespace($a) {
    $a = get;
  }
  $b = get;
  $c = get;
  $d = get;

  while $a {
    if is-whitespace($a) {
      die 'minifier bug: minify while loop starting with whitespace, stopped';
    }
    process-char();
  }

  return restore-nocompress(@out.join, @nocompress_blocks);
}

sub js-minifier(:$input!, Str :$copyright = '', :$stream,
                Bool :$strip_debug = False,
                Bool :$keep_bang_comments = False,
                Bool :$drop_console = False,
                Bool :$drop_debugger = False,
                Bool :$nocompress = False,
                Bool :$aggressive = False) is export {

  if $stream ~~ Channel {
    my $result = try {
      minify-core(:$input, :$copyright, :$strip_debug, :$keep_bang_comments,
                  :$drop_console, :$drop_debugger, :$nocompress, :$aggressive);
    }
    if $! {
      $stream.close;
      die $!;
    }
    $stream.send($result);
    $stream.close;
    return;
  }

  minify-core(:$input, :$copyright, :$strip_debug, :$keep_bang_comments,
              :$drop_console, :$drop_debugger, :$nocompress, :$aggressive);
}

our &js-minify is export = &js-minifier;