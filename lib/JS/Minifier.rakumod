use v6;

unit module JS::Minifier;

sub is-alphanum(Str $x) returns Bool {
  so $x ne "" && ($x gt '~' || '$\\'.contains($x) ||
    $x ~~ '0'..'9' ||
    $x ~~ 'A'..'Z' ||
    $x eq '_' ||
    $x ~~ 'a'..'z');
}

sub is-endspace(Str $x) returns Bool {
  $x ne "" && "\n\f\r".contains($x);
}

sub is-whitespace(Str $x) returns Bool {
  ($x ne "" && (ord($x) == 32 || ord($x) == 9)) || is-endspace $x;
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

sub get(%s) returns List {
  return ["", %s<input_pos>] unless %s<input_pos> < %s<input>.elems;
  my Str $char = %s<input>[%s<input_pos>] // "";
  %s<input_pos>++;
  $char, %s<input_pos>;
}

sub step-chr-a(%s) {
  %s<lastnws> = %s<a> unless is-whitespace %s<a>;
  %s<last>    = %s<a>;
  send-chr-out %s;
}

sub send-chr-out(%s) {
  %s<output>.send: %s<a>;
  delete-chr-a %s;
}

sub delete-chr-a(%s) {
  %s<a> = %s<b>;
  delete-chr-b %s;
}

sub delete-chr-b(%s) {
  (%s<b>, %s<c>) = (%s<c>, %s<d>);
  (%s<d>, %s<input_pos>) = get %s;
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
        if %s<a> eq '`' || %s<a> eq "'" || %s<a> eq '"' || (%s<a> eq '/' && is-regex-start(%s<lastnws>)) {
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
  return skip-whitespace(%s) if %s<aggressive>;
  %s = collapse-whitespace(%s);
  if is-endspace(%s<a>) && !is-postfix(%s<b>) {
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
    %s<a> = ' ' if %s<aggressive> && is-endspace(%s<a>);
    if %s<b> && (is-alphanum(%s<b>) || %s<b> eq '.') {
      step-chr-a(%s);
    } else {
      preserve-endspace(%s);
    }
  }
  %s;
}

sub skip-matching-paren(%s, Str $open, Str $close) returns Hash {
  my Int $depth = 1;
  while $depth > 0 && %s<a> {
    if %s<a> eq $open {
      $depth++;
    } elsif %s<a> eq $close {
      $depth--;
    }
    delete-chr-a(%s);
  }
  return %s;
}

multi sub process-comments(%s where {%s<b> eq '/'}) returns Hash {
  my Bool $cc_flag = %s<c> eq '@';

  repeat {
    if $cc_flag {
      send-chr-out %s;
    } else {
      delete-chr-a(%s);
    }
  } until (!%s<a> || is-endspace(%s<a>));

  if $cc_flag {
    step-chr-a(%s);
    skip-whitespace(%s);
  } elsif %s<last> && !is-endspace(%s<last>) && !is-prefix(%s<last>) {
    return preserve-endspace %s;
  } else {
    return skip-whitespace %s;
  }
}

multi sub process-comments(%s where {%s<b> eq '*'}) returns Hash {
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
    for @buf -> $c {
      %s<output>.send($c);
    }
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
    %s;
  } elsif (%s<last> && !is-prefix(%s<last>)) {
    return preserve-endspace %s;
  } else {
    return skip-whitespace %s;
  }
}

my constant $REGEX-START = set <return typeof throw delete void case new in instanceof yield export import extends super await>;
my constant $VAR-LET-CONST = set <var let const>;

sub is-regex-start(Str $w) returns Bool {
  so $w ∈ $REGEX-START;
}

multi sub process-comments(%s where {%s<lastnws> &&
                           (')]}.'.contains(%s<lastnws>) ||
                           (is-alphanum(%s<lastnws>) && !is-regex-start(%s<lastnws>)))}) returns Hash {
  step-chr-a(%s);
  collapse-whitespace(%s);
  process-conditional-comment(%s);
}

multi sub process-comments(%s where {%s<lastnws>.defined and %s<a> eq '/' and %s<b> eq '.' and !is-regex-start(%s<lastnws>)}) returns Hash {
  collapse-whitespace(%s);
  step-chr-a(%s);
}

multi sub process-comments(%s) returns Hash {
  %s.&put-literal.&collapse-whitespace.&process-conditional-comment;
}

multi sub process-char(%s where {%s<a> eq '/'}) returns Hash {
  process-comments %s;
}

multi sub process-char(%s where { "'\"`".contains(%s<a>) }) returns Hash {
  %s.&put-literal.&preserve-endspace;
}

multi sub process-char(%s where { '+-'.contains(%s<a>) }) returns Hash {
  step-chr-a(%s);
  collapse-whitespace(%s);
  process-double-plus-minus(%s);
}

multi sub process-char(%s where { is-alphanum(%s<a>) }) returns Hash {
  my @id;
  while %s<a> && is-alphanum(%s<a>) {
    @id.push(%s<a>);
    delete-chr-a(%s);
  }
  my Str $id = @id.join;

  if $id eq 'debugger' && %s<drop_debugger> {
    %s = collapse-whitespace %s;
    %s = skip-whitespace %s;
    if %s<a> eq ';' {
      delete-chr-a(%s);
    }
    %s = skip-whitespace %s;
    return %s;
  }

  if $id eq 'console' && %s<drop_console> {
    %s = collapse-whitespace %s;
      if %s<a> eq '.' {
        delete-chr-a(%s);
        %s = collapse-whitespace %s;
        %s = skip-whitespace %s;
        my @method;
        while %s<a> && is-alphanum(%s<a>) {
          @method.push(%s<a>);
          delete-chr-a(%s);
        }
        my $method = @method.join;
        %s = collapse-whitespace %s;
        %s = skip-whitespace %s;
        if %s<a> eq '(' {
        %s = skip-matching-paren %s, '(', ')';
        %s = collapse-whitespace %s;
        if %s<a> eq ';' {
          delete-chr-a(%s);
        }
        %s = skip-whitespace %s;
        return %s;
      }
      %s<output>.send('console.' ~ $method);
      %s<lastnws> = $method;
      %s<last> = $method.substr(*-1, 1);
    } else {
      %s<output>.send('console');
      %s<lastnws> = 'console';
      %s<last>    = 'console';
    }
    %s = collapse-whitespace %s;
    %s = process-property-invocation %s;
    return %s;
  }

  my %shorten = 'true' => '!0', 'false' => '!1';
  if %shorten{$id}:exists {
    if (%s<lastnws> // '') ∈ $VAR-LET-CONST || %s<lastnws> eq '.'
        || %s<a> eq ':' || (is-whitespace(%s<a>) && %s<b> eq ':')
        || %s<a> eq '(' {
      %s<output>.send($id);
    } else {
      %s<output>.send(%shorten{$id});
    }
  } else {
    %s<output>.send($id);
  }
  %s<lastnws> = $id;
  %s<last>    = $id.substr(*-1, 1);
  collapse-whitespace(%s);
  process-property-invocation(%s);
}

multi sub process-char(%s where { %s<a> eq ';' }) returns Hash {
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
}

multi sub process-char(%s where { ']})'.contains(%s<a>) }) returns Hash {
  step-chr-a(%s);
  preserve-endspace(%s);
}

multi sub process-char(%s) returns Hash {
  step-chr-a(%s);
  skip-whitespace(%s);
}

multi sub output-manager(Channel $output, Channel $stream) returns Promise {
  start {
    for $output.list -> $c {
      if $c eq 'exit' {
        $stream.close;
        last;
      }
      $stream.send($c);
    }
    return;
  }
}

multi sub output-manager(Channel $output) returns Promise {
  start {
    my Str @buf;
    for $output.list -> $c {
      last if $c eq 'exit';
      @buf.push($c);
    }
    @buf.join;
  }
}

sub js-minifier(:$input!, Str :$copyright = '', :$stream,
                Bool :$strip_debug = False,
                Bool :$keep_bang_comments = False,
                Bool :$drop_console = False,
                 Bool :$drop_debugger = False,
                 Bool :$nocompress = False,
                 Bool :$aggressive = False) is export {

  my Str $input_new = $input ~~ Str ?? $input !! $input.readchars;

  my Str $preprocessed = $input_new;
  my %nocompress_blocks;

  if $strip_debug {
    $preprocessed = $preprocessed.subst(/ ';;;' <-[\n]>* \n? /, '', :g);
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
      %nocompress_blocks{$key} = $block;
      @processed.push($key);
      $pos = $end + $END_TAG.chars;
      $idx++;
    }
    @processed.push(substr($preprocessed, $pos));
    $preprocessed = @processed.join;
  }

  my Str @input_list = $preprocessed.comb;

  unless @input_list {
    my $empty_result = $copyright ?? "/* $copyright */" !! '';
    return $empty_result unless $stream ~~ Channel;
    $stream.send($empty_result) if $empty_result.chars;
    $stream.close;
    return;
  }

  my %s = input             => @input_list,
          input_pos         => 0,
          output            => Channel.new,
          last              => Str,
           lastnws           => Str,
          keep_bang_comments => $keep_bang_comments,
           drop_console      => $drop_console,
           drop_debugger     => $drop_debugger,
           aggressive        => $aggressive;

  my Promise $output = (given $stream {
                          when Channel { output-manager(%s<output>, $stream) }
                          default      { output-manager(%s<output>) }
                        });

  if $copyright {
    %s<output>.send("/* $copyright */");
  }

  my Bool $shebang = @input_list && @input_list[0] eq '#' && @input_list.elems > 1 && @input_list[1] eq '!';
  if $shebang {
    my $idx = 2;
    my @shebang_line;
    while $idx < @input_list.elems && @input_list[$idx] ne "\n" {
      @shebang_line.push(@input_list[$idx]);
      $idx++;
    }
    @shebang_line.push("\n") if $idx < @input_list.elems && @input_list[$idx] eq "\n";
    %s<output>.send('#!' ~ @shebang_line.join);
    %s<input_pos> = $idx;
    %s<input_pos>++ if $idx < @input_list.elems && @input_list[$idx] eq "\n";
    if %s<input_pos> >= @input_list.elems {
      %s<output>.send('exit');
      return $output.result unless $stream ~~ Channel;
      return;
    }
  }

  repeat {
    (%s<a>, %s<input_pos>) = get %s;
  } while (%s<a> && is-whitespace(%s<a>));
  (%s<b>, %s<input_pos>)   = get %s;
  (%s<c>, %s<input_pos>)   = get %s;
  (%s<d>, %s<input_pos>)   = get %s;

  my $minify_error;
  start {
    while %s<a> {
      if (is-whitespace(%s<a>)) {
        die 'minifier bug: minify while loop starting with whitespace, stopped';
      }
      %s = process-char %s;
    }
    CATCH {
      default {
        $minify_error = $_;
        %s<output>.send: 'exit';
        return;
      }
    }
    %s<output>.send: 'exit';
  }

  my $result = $output.result;
  die $minify_error if $minify_error;
  return if $stream ~~ Channel;

  if $nocompress && %nocompress_blocks {
    for %nocompress_blocks.kv -> $key, $value {
      $result .= subst($key, $value, :g);
    }
  }

  $result;
}

my &js-minify := &js-minifier;
