use v6.d;

unit module JS::Minifier;

my constant %SHORTEN    = 'true' => '!0', 'false' => '!1';

sub is-alphanum(Str $x) returns Bool {
  return False if $x eq '';
  my Int $o = ord($x);
  return True if $o >= 48 && $o <= 57;   # 0-9
  return True if $o >= 65 && $o <= 90;   # A-Z
  return True if $o >= 97 && $o <= 122;  # a-z
  return True if $x eq '_' || $x eq '$' || $x eq '\\';
  return True if $o > 126;               # approximation for non-ASCII
  False;
}

sub is-endspace(Str $x) returns Bool {
  return False if $x eq '';
  my Int $o = ord($x);
  $o == 10 || $o == 12 || $o == 13 || $o == 8232 || $o == 8233;
}

sub is-whitespace(Str $x) returns Bool {
  return False if $x eq '';
  my Int $o = ord($x);
  $o == 11 || $o == 32 || $o == 9 || $o == 10 || $o == 12 || $o == 13 ||
    $o == 8232 || $o == 8233;
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

sub get(%s) returns Str {
  my Int $pos = %s<input_pos>;
  my Int $len = %s<input_len>;
  return '' if $pos >= $len;
  %s<input_pos> = $pos + 1;
  %s<input>.substr($pos, 1);
}

sub step-chr-a(%s) {
  if !is-whitespace(%s<a>) {
    %s<prevnws> = %s<lastnws>;
    %s<lastnws> = %s<a>;
  }
  %s<last> = %s<a>;
  %s<out>.push(%s<a>) if %s<a>;
  %s<a> = %s<b>;
  %s<b> = %s<c>;
  %s<c> = %s<d>;
  %s<d> = get %s;
}

sub send-chr-out(%s) {
  %s<out>.push(%s<a>) if %s<a>;
  %s<a> = %s<b>;
  %s<b> = %s<c>;
  %s<c> = %s<d>;
  %s<d> = get %s;
}

sub delete-chr-a(%s) {
  %s<a> = %s<b>;
  %s<b> = %s<c>;
  %s<c> = %s<d>;
  %s<d> = get %s;
}

sub delete-chr-b(%s) {
  %s<b> = %s<c>;
  %s<c> = %s<d>;
  %s<d> = get %s;
}

sub put-literal(%s) returns Hash {
  my Str $delimiter = %s<a>;

  if $delimiter eq '`' {
    step-chr-a(%s);
    my Int $brace-depth = 0;
    loop {
      while %s<a> eq '\\' {
        step-chr-a(%s); step-chr-a(%s);
      }
      if %s<a> eq '`' && $brace-depth == 0 {
        step-chr-a(%s);
        last;
      }
      if %s<a> eq '$' && %s<b> eq '{' && $brace-depth == 0 {
        step-chr-a(%s);
        step-chr-a(%s);
        $brace-depth = 1;
        next;
      }
      if $brace-depth > 0 {
        if !%s<a> {
          die 'unterminated template literal expression, stopped';
        }
        if %s<a> eq '`' || %s<a> eq "'" || %s<a> eq '"' || (%s<a> eq '/' && is-regex-literal(%s)) {
          %s = put-literal %s;
          next;
        }
        if %s<a> eq '{' {
          $brace-depth++;
        } elsif %s<a> eq '}' {
          $brace-depth--;
          if $brace-depth == 0 {
            step-chr-a(%s);
            next;
          }
        }
      }
      step-chr-a(%s);
      if !%s<a> && $brace-depth == 0 {
        die 'unterminated template literal, stopped';
      }
    }
    %s<last_was_regex> = False;
    return %s;
  }

  step-chr-a(%s);
  loop {
    while %s<a> eq '\\' {
      if is-endspace(%s<b>) {
        delete-chr-a(%s);
        delete-chr-a(%s);
        next;
      }
      step-chr-a(%s);
      step-chr-a(%s);
    }
    step-chr-a(%s);
    last if %s<last> eq $delimiter || !%s<a>;
  }

  %s<last_was_regex> = $delimiter eq '/';

  given %s<last> {
    when $delimiter { %s }
    default {
      die 'unterminated single quoted string literal, stopped' if $delimiter eq '\'';
      die 'unterminated double quoted string literal, stopped' if $delimiter eq '"';
      die 'unterminated regular expression literal, stopped';
    }
  }
}

sub collapse-whitespace(%s) returns Hash {
  while (is-whitespace(%s<a>) &&
         is-whitespace(%s<b>)) {
    %s<a> = "\n" if (is-endspace(%s<a>) || is-endspace(%s<b>));
    delete-chr-b(%s);
  }
  return %s;
}

sub skip-whitespace(%s) returns Hash {
  while (is-whitespace(%s<a>)) {
    delete-chr-a(%s);
  }
  return %s;
}

sub preserve-endspace(%s) returns Hash {
  %s = collapse-whitespace(%s);
  if is-endspace(%s<a>) && !is-postfix(%s<b>) && !(%s<aggressive> && %s<b> eq '.') {
    # In aggressive mode a '.' can only continue an expression, so the
    # separator before it is unnecessary; otherwise keep the newline so
    # automatic-semicolon-insertion semantics are preserved.
    step-chr-a(%s);
  }
  skip-whitespace(%s)
}

sub on-whitespace-conditional-comment(Str $a, Str $b, Str $c, Str $d) returns Bool {
  is-whitespace($a) && $b eq '/' && ($c eq '/' || $c eq '*') && $d eq '@';
}

sub process-conditional-comment(%s) returns Hash {
  if on-whitespace-conditional-comment(%s<a>, %s<b>, %s<c>, %s<d>) {
    step-chr-a(%s);
    %s;
  } else {
    preserve-endspace %s
  }
}

sub process-double-plus-minus(%s) returns Hash {
  if is-whitespace(%s<a>) {
    if %s<b> eq %s<last> {
      step-chr-a(%s);
    } else {
      preserve-endspace(%s);
    }
  }
  %s;
}

sub process-property-invocation(%s) returns Hash {
  if is-whitespace(%s<a>) {
    if %s<b> && (is-alphanum(%s<b>) || (%s<b> eq '.' && !%s<aggressive>)) {
      # Need a separator before a following identifier/number, or (outside
      # aggressive mode) before a member access; keep a single whitespace char.
      step-chr-a(%s);
    } elsif %s<b> eq '.' {
      # Aggressive mode: a member-access separator is unnecessary.
      skip-whitespace(%s);
    } else {
      preserve-endspace(%s);
    }
  }
  %s;
}

sub skip-matching-paren(%s, Str $open, Str $close) returns Hash {
  my Int $depth = 1;
  %s<prevnws> = %s<lastnws>;
  %s<lastnws> = $open;
  %s<last> = $open;
  while $depth && %s<a> {
    my Str $c = %s<a>;
    if $c eq '/' {
      if %s<b> eq '*' {
        while %s<a> && !(%s<a> eq '*' && %s<b> eq '/') {
          delete-chr-a(%s);
        }
        die 'unterminated comment, stopped' unless %s<a>;
        delete-chr-a(%s);
        delete-chr-a(%s);
        next;
      }
      if %s<b> eq '/' {
        while %s<a> && !is-endspace(%s<a>) {
          delete-chr-a(%s);
        }
        next;
      }
      if is-regex-literal(%s) {
        my $out_start = %s<out>.elems;
        %s = put-literal(%s);
        %s<out>.splice($out_start);
        next;
      }
    }
    if $c eq "'" || $c eq '"' || $c eq '`' {
      my $out_start = %s<out>.elems;
      %s = put-literal(%s);
      %s<out>.splice($out_start);
      next;
    }
    if $c eq $open  { $depth++; }
    if $c eq $close { $depth--; }
    if !is-whitespace($c) {
      %s<prevnws> = %s<lastnws>;
      %s<lastnws> = $c;
    }
    %s<last> = $c;
    delete-chr-a(%s);
  }
  return %s;
}

my constant $REGEX-START = set <return typeof throw delete void case new in instanceof yield export import extends super await>;
my constant $VAR-LET-CONST = set <var let const>;

sub is-regex-start(Str $w) returns Bool {
  so $w ∈ $REGEX-START;
}

# Whether the '/' at %s<a> opens a regular expression literal, as opposed
# to being a division operator. Mirrors the heuristic used in
# process-comments. A '/' whose previous non-whitespace char is itself a '/'
# is a regex unless that slash closed a regex literal (then it is division).
# A quote/template-literal closer is a division trigger only when the '/'
# follows on the same line (no endspace crossed since).
sub is-regex-literal(%s) returns Bool {
  my Str $ln = %s<lastnws>;
  return True if !$ln;
  if $ln eq '/' {
    return %s<last_was_regex> ?? False !! True;
  }
  return False if ')]}.'.contains($ln);
  if $ln eq '"' || $ln eq "'" || $ln eq '`' {
    return is-endspace(%s<last>) ?? True !! False;
  }
  return False if is-alphanum($ln) && !is-regex-start($ln);
  return False if ($ln eq '+' || $ln eq '-') && %s<prevnws> eq $ln;
  return False if %s<b> eq '.' && !is-regex-start($ln);
  True;
}

sub process-comments(%s) returns Hash {
  if %s<b> eq '/' {
    my Bool $cc_flag = %s<c> eq '@';

    repeat {
      if $cc_flag {
        send-chr-out(%s);
      } else {
        delete-chr-a(%s);
      }
    } until (!%s<a> || is-endspace(%s<a>));

    if $cc_flag {
      step-chr-a(%s);
      skip-whitespace(%s);
      return %s;
    }
    if %s<last> && !is-endspace(%s<last>) && !is-prefix(%s<last>) {
      return preserve-endspace(%s);
    }
    return skip-whitespace(%s);
  }

  if %s<b> eq '*' {
    my Bool $cc_flag = %s<c> eq '@';
    my Bool $bang_flag = %s<keep_bang_comments> && %s<c> eq '!';

    # For IE conditional comments and bang comments: output verbatim
    if $cc_flag || $bang_flag {
      my @buf;
      loop {
        last if !%s<b> || (%s<a> eq '*' && %s<b> eq '/');
        @buf.push(%s<a>);
        delete-chr-a(%s);
      }
      die 'unterminated comment, stopped' unless %s<b>;
      if $bang_flag {
        @buf.pop while @buf && is-whitespace(@buf[*-1]);
      }
      %s<out>.push(@buf.join);
      send-chr-out(%s);
      send-chr-out(%s);
      return preserve-endspace(%s);
    }

    # For regular comments: consume and discard
    loop {
      last if !%s<b> || (%s<a> eq '*' && %s<b> eq '/');
      delete-chr-a(%s);
    }

    die 'unterminated comment, stopped' unless %s<b>;

    # Remove the closing * and /
    delete-chr-a(%s);
    %s<a> = ' ';
    %s = collapse-whitespace %s;

    if (%s<last> && %s<b> &&
        ((is-alphanum(%s<last>) && ( is-alphanum(%s<b>) || %s<b> eq '.')) ||
         (%s<last> eq '+' && %s<b> eq '+') ||
         (%s<last> eq '-' && %s<b> eq '-') )) {
      step-chr-a(%s);
      return %s;
    }
    if (%s<last> && !is-prefix(%s<last>)) {
      return preserve-endspace(%s);
    }
    return skip-whitespace(%s);
  }

  my $ln = %s<lastnws>;
  if $ln && (')]}.'.contains($ln) ||
             (($ln eq '"' || $ln eq "'" || $ln eq '`') && !is-endspace(%s<last>)) ||
             (is-alphanum($ln) && !is-regex-start($ln)) ||
             (($ln eq '+' || $ln eq '-') && %s<prevnws> eq $ln) ||
             ($ln eq '/' && %s<last_was_regex>)) {
    %s<last_was_regex> = False;
    %s<out>.push(' ') if %s<last> eq '/';
    step-chr-a(%s);
    collapse-whitespace(%s);
    return process-conditional-comment(%s);
  }

  if $ln ne '' && %s<b> eq '.' && !is-regex-start($ln) {
    %s<last_was_regex> = False;
    %s<out>.push(' ') if %s<last> eq '/';
    collapse-whitespace(%s);
    step-chr-a(%s);
    return %s;
  }

  %s<out>.push(' ') if %s<last> eq '/';
  %s.&put-literal.&collapse-whitespace.&process-conditional-comment;
}

sub read-id(%s) returns Str {
  my @id;
  while %s<a> && is-alphanum(%s<a>) {
    @id.push(%s<a>);
    delete-chr-a(%s);
  }
  @id.join;
}

sub process-char(%s) returns Hash {
  my Str $a = %s<a>;
  if $a eq '/' {
    return process-comments %s;
  }
  if "'\"`".contains($a) {
    return %s.&put-literal.&preserve-endspace;
  }
  if $a eq '+' || $a eq '-' {
    step-chr-a(%s);
    collapse-whitespace(%s);
    return process-double-plus-minus(%s);
  }
  if $a eq ';' {
    while is-whitespace(%s<b>) {
      delete-chr-b(%s);
    }
    if %s<b> eq '}' {
      delete-chr-a(%s);
      %s<last> = '}';
      return %s;
    }
    step-chr-a(%s);
    skip-whitespace(%s);
    return %s;
  }
  if ']})'.contains($a) {
    step-chr-a(%s);
    return preserve-endspace(%s);
  }
  if is-alphanum($a) {
    my Str $id = read-id %s;

    # After a regular-expression literal, an immediately adjacent keyword
    # that begins with a letter (e.g. in / instanceof) would otherwise be
    # consumed as a regex flag, producing invalid output
    # (e.g. "/re/instanceof" -> "Invalid regular expression flags"). Only
    # "in" and "instanceof" can legally follow a regex operand, and both
    # require a space to keep the output valid. The immediate-predecessor
    # check (lastnws eq '/') prevents a stale regex flag from adding a
    # redundant space when the keyword follows something else.
    if %s<last_was_regex> && %s<lastnws> eq '/' && ($id eq 'in' || $id eq 'instanceof') {
      %s<out>.push(' ');
    }

    if $id eq 'debugger' && %s<drop_debugger> {
      my $prev = %s<lastnws>;
      if $prev eq '' || $prev eq ';' || $prev eq '{' || $prev eq '}' {
        my %probe = %s.clone;
        %probe = collapse-whitespace %probe;
        %probe = skip-whitespace %probe;
        if %probe<a> eq ';' || %probe<a> eq '}' || !%probe<a> {
          if %probe<a> eq ';' {
            delete-chr-a(%probe);
          }
          %probe = skip-whitespace %probe;
          return %probe;
        }
      }
    }

    if $id eq 'console' && %s<drop_console> {
      # Only drop a standalone "console.method(args)" statement. A console
      # call used as a sub-expression (e.g. "console.log(x).toString()" or
      # "a = console.log(x)") is kept so the output remains valid JS.
      # Probe a clone of the state to decide without mutating the real stream.
      my $prev = %s<lastnws>;
      my Bool $dropit = $prev eq '' || $prev eq ';' || $prev eq '{' || $prev eq '}';
      if $dropit {
        my %probe = %s.clone;
        %probe = collapse-whitespace %probe;
        if %probe<a> eq '.' {
          delete-chr-a(%probe);                # consume '.'
          %probe = collapse-whitespace %probe;
          %probe = skip-whitespace %probe;
          my $probe_method = read-id %probe;
          %probe = collapse-whitespace %probe;
          %probe = skip-whitespace %probe;
          $dropit = so($probe_method.chars && %probe<a> eq '(');
          if $dropit {
            delete-chr-a(%probe);              # consume '('
            %probe = skip-matching-paren %probe, '(', ')';
            %probe = skip-whitespace %probe;
            $dropit = %probe<a> eq ';' || %probe<a> eq '}' || !%probe<a>;
          }
        } else {
          $dropit = False;
        }
      }

      if $dropit {
        my $saved_prevnws = %s<prevnws>;
        my $saved_lastnws = %s<lastnws>;
        my $saved_last    = %s<last>;
        my $saved_last_was_regex = %s<last_was_regex>;
        %s = collapse-whitespace %s;
        delete-chr-a(%s);                      # consume '.'
        %s = collapse-whitespace %s;
        %s = skip-whitespace %s;
        my $method = read-id %s;
        %s = collapse-whitespace %s;
        %s = skip-whitespace %s;
        delete-chr-a(%s);                      # consume '('
        %s = skip-matching-paren %s, '(', ')';
        %s = skip-whitespace %s;
        if %s<a> eq ';' {
          delete-chr-a(%s);
        }
        %s = skip-whitespace %s;
        %s<prevnws> = $saved_prevnws;
        %s<lastnws> = $saved_lastnws;
        %s<last>    = $saved_last;
        %s<last_was_regex> = $saved_last_was_regex;
        return %s;
      }

      # Not a droppable statement — keep the console expression verbatim.
      %s = collapse-whitespace %s;
      if %s<a> eq '.' {
        delete-chr-a(%s);
        %s = collapse-whitespace %s;
        %s = skip-whitespace %s;
        my $method = read-id %s;
        %s = collapse-whitespace %s;
        %s = skip-whitespace %s;
        %s<out>.push('console.' ~ $method);
        %s<prevnws> = %s<lastnws>;
        %s<lastnws> = $method;
        %s<last> = $method.chars ?? $method.substr(*-1, 1) !! '.';
      } else {
        %s<out>.push('console');
        %s<prevnws> = %s<lastnws>;
        %s<lastnws> = 'console';
        %s<last> = 'console';
      }
      %s = collapse-whitespace %s;
      %s = process-property-invocation %s;
      return %s;
    }

    if (%SHORTEN{$id}:exists) {
      if %s<lastnws> ∈ $VAR-LET-CONST || %s<lastnws> eq '.'
          || %s<a> eq ':' || (is-whitespace(%s<a>) && %s<b> eq ':')
          || %s<a> eq '(' || %s<a> eq '.' || %s<a> eq '[' {
        %s<out>.push($id);
        %s<last> = $id.substr(*-1, 1);
      } else {
        %s<out>.push(%SHORTEN{$id});
        %s<last> = %SHORTEN{$id}.substr(*-1, 1);
      }
    } else {
      %s<out>.push($id);
      %s<last> = $id.substr(*-1, 1);
    }
    %s<prevnws> = %s<lastnws>;
    %s<lastnws> = $id;
    %s = collapse-whitespace %s;
    %s = process-property-invocation %s;
    return %s;
  }
  step-chr-a(%s);
  skip-whitespace(%s);
  %s;
}

sub restore-nocompress(Str $result, @nocompress_blocks, Bool $nocompress) returns Str {
  if $nocompress && @nocompress_blocks {
    my $out = $result;
    for @nocompress_blocks -> $block {
      $out .= subst($block[0], $block[1], :g);
    }
    return $out;
  }
  $result;
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

  my Str $preprocessed = $input_new;
  my @nocompress_blocks;

  if $strip_debug {
    $preprocessed = $preprocessed.subst(/ [ ^ | <?after \n> ] \s* ";;;" <-[\n]>* \n? /, '', :g);
  }

  if $nocompress {
    constant $BEGIN_TAG = '/* BEGIN NOCOMPRESS */';
    constant $END_TAG   = '/* END NOCOMPRESS */';
    my Str @processed;
    my $pos = 0;
    my $idx = 0;
    loop {
      my $begin = index($preprocessed, $BEGIN_TAG, $pos);
      last unless $begin.defined;
      @processed.push(substr($preprocessed, $pos, $begin - $pos));
      my $end = index($preprocessed, $END_TAG, $begin);
      die 'unterminated NOCOMPRESS block, stopped' unless $end.defined;
      my $block = substr($preprocessed, $begin + $BEGIN_TAG.chars, $end - $begin - $BEGIN_TAG.chars);
      my $key = "\x00N" ~ $idx ~ "N\x00";
      @nocompress_blocks.push([$key, $block]);
      @processed.push($key);
      $pos = $end + $END_TAG.chars;
      $idx++;
    }
    @processed.push(substr($preprocessed, $pos));
    $preprocessed = @processed.join;
  }

  unless $preprocessed.chars {
    return $copyright ?? "/* $copyright */" !! '';
  }

  my Int $input_len = $preprocessed.chars;

  my %s = input             => $preprocessed,
          input_len         => $input_len,
          input_pos         => 0,
          out               => [],
          last              => '',
          prevnws           => '',
          lastnws           => '',
          keep_bang_comments => $keep_bang_comments,
          drop_console      => $drop_console,
          drop_debugger     => $drop_debugger,
          last_was_regex    => False,
          aggressive        => $aggressive;

  if $copyright {
    %s<out>.push("/* $copyright */");
  }

  my Bool $shebang = $input_len > 1 && $preprocessed.substr(0, 1) eq '#' && $preprocessed.substr(1, 1) eq '!';
  if $shebang {
    my $idx = 2;
    my @shebang_line;
    while $idx < $input_len && !is-endspace($preprocessed.substr($idx, 1)) {
      @shebang_line.push($preprocessed.substr($idx, 1));
      $idx++;
    }
    @shebang_line.push("\n") if $idx < $input_len && is-endspace($preprocessed.substr($idx, 1));
    %s<out>.push('#!' ~ @shebang_line.join);
    %s<input_pos> = $idx;
    %s<input_pos>++ if $idx < $input_len && is-endspace($preprocessed.substr($idx, 1));
    if %s<input_pos> >= $input_len {
      return restore-nocompress(%s<out>.join, @nocompress_blocks, $nocompress);
    }
  }

  %s<a> = get %s;
  while %s<a> && is-whitespace(%s<a>) {
    %s<a> = get %s;
  }
  %s<b> = get %s;
  %s<c> = get %s;
  %s<d> = get %s;

  while %s<a> {
    if is-whitespace(%s<a>) {
      die 'minifier bug: minify while loop starting with whitespace, stopped';
    }
    %s = process-char %s;
  }

  return restore-nocompress(%s<out>.join, @nocompress_blocks, $nocompress);
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
    $stream.send($result) if $result.chars;
    $stream.close;
    return;
  }

  minify-core(:$input, :$copyright, :$strip_debug, :$keep_bang_comments,
              :$drop_console, :$drop_debugger, :$nocompress, :$aggressive);
}

our &js-minify is export = &js-minifier;
