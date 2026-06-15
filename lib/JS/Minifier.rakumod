use v6;

unit module JS::Minifier;

sub is-alphanum(Str $x) returns Bool {
  so $x.chars && (ord($x) > 126 || '$\\'.contains($x) || $x ~~ / \w /.Bool);
}

sub is-endspace(Str $x) returns Bool {
  $x ~~ "\n"|"\f"|"\r";
}

sub is-whitespace(Str $x) returns Bool {
  $x ~~ / \h /.Bool || is-endspace $x;
}

sub is-infix(Str $x) returns Bool {
  so $x.chars && ",;:=&%*<>?|\n".contains: $x;
}

sub is-prefix(Str $x) returns Bool {
  so $x.chars && ('{([!'.contains($x) || is-infix $x);
}

sub is-postfix(Str $x) returns Bool {
  so $x.chars && '})]'.contains: $x;
}

sub get(%s) returns List {
  given %s<input>.elems {
    when *>0 {
      return ["", %s<last_read_char>, %s<input_pos>] unless %s<input_pos> < %s<input>.elems;
      my $raw = %s<input>[%s<input_pos>];
      my Str $char = $raw // "";
      my Str $last_read_char = %s<input>[%s<input_pos>++] // "";
      if $char eq "\n" {
        %s<line>++;
        %s<column> = 0;
      } else {
        %s<column>++;
      }
      $char, $last_read_char, %s<input_pos>;
    }
    default {
      die 'no input';
    }
  }
}

sub step-chr-a(%s) returns Hash {
  %s<lastnws> = %s<a> unless is-whitespace %s<a>;
  %s<last>    = %s<a>;
  send-chr-out %s;
}

sub send-chr-out(%s) returns Hash {
  %s<output>.send: %s<a>;
  delete-chr-a %s;
}

sub delete-chr-a(%s) returns Hash {
  %s<a> = %s<b>;
  delete-chr-b %s;
}

sub delete-chr-b(%s) returns Hash {
  (%s<b>, %s<c>) = (%s<c>, %s<d>);
  (%s<d>, %s<last_read_char>, %s<input_pos>) = get %s;
  return %s;
}

sub put-literal(%s) returns Hash {
  my Str $delimiter = %s<a>;

  if $delimiter eq '`' {
    %s = step-chr-a %s;
    my Int $brace-depth = 0;
    loop {
      while %s<a> eq '\\' {
        %s = %s.&step-chr-a.&step-chr-a;
      }
      if %s<a> eq '`' && $brace-depth == 0 {
        %s = step-chr-a %s;
        last;
      }
      if %s<a> eq '$' && %s<b> eq '{' && $brace-depth == 0 {
        %s = step-chr-a %s;
        %s = step-chr-a %s;
        $brace-depth = 1;
        next;
      }
      if $brace-depth > 0 {
        if %s<a> eq '{' {
          $brace-depth++;
        } elsif %s<a> eq '}' {
          $brace-depth--;
          if $brace-depth == 0 {
            %s = step-chr-a %s;
            next;
          }
        }
      }
      %s = step-chr-a %s;
      if !%s<a> && $brace-depth == 0 {
        die 'unterminated template literal, stopped';
      }
    }
    return %s;
  }

  %s = step-chr-a %s;
  loop {
    while %s<a> eq '\\' {
      if is-endspace(%s<b>) {
        %s = delete-chr-a %s;
        %s = delete-chr-a %s;
        next;
      }
      %s = %s.&step-chr-a;
      %s = step-chr-a %s;
    }
    %s = step-chr-a %s;
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
    %s = delete-chr-b %s;
  }
  return %s;
}

sub skip-whitespace(%s) returns Hash {
  while (is-whitespace(%s<a>)) {
    %s = delete-chr-a %s;
  }
  return %s;
}

sub preserve-endspace(%s) returns Hash {
  %s = collapse-whitespace(%s);
  if is-endspace(%s<a>) && !is-postfix(%s<b>) {
    %s = step-chr-a(%s);
  }
  skip-whitespace(%s);
 }

sub on-whitespace-conditional-comment(Str $a, Str $b, Str $c, Str $d) returns Bool {
  is-whitespace($a) && $b eq '/' && ('/*'.contains($c) &&  $d eq '@').Bool;
}

sub process-conditional-comment(%s) returns Hash {
  given on-whitespace-conditional-comment(|%s{'a' .. 'd'}) {
    when * eq True { step-chr-a %s }
    default { preserve-endspace %s }
  }
}

sub process-double-plus-minus(%s) returns Hash {
  given %s<a> {
    when is-whitespace(%s<a>) {
      (%s<b> eq %s<last>) ?? step-chr-a(%s) !! preserve-endspace(%s);
    }
    default { %s }
  }
};

sub process-property-invocation(%s) returns Hash {
  (given %s<a> {
     when $_ && is-whitespace($_) {
      (%s<b> && (is-alphanum(%s<b>) || %s<b> eq '.')) ?? step-chr-a(%s) !! preserve-endspace(%s);
     }
     default { %s }
   });
}

sub skip-matching-paren(%s, Str $open, Str $close) returns Hash {
  my Int $depth = 1;
  while $depth > 0 && %s<a> {
    if %s<a> eq $open {
      $depth++;
    } elsif %s<a> eq $close {
      $depth--;
    }
    %s = delete-chr-a %s;
  }
  return %s;
}

multi sub process-comments(%s where {%s<b> eq '/'}) returns Hash {
  my Bool $cc_flag = %s<c> eq '@';

  repeat {
    %s = $cc_flag ?? send-chr-out %s !! delete-chr-a %s;
  } until (!%s<a> || is-endspace(%s<a>));

  (given $cc_flag {
     when $_ {
       %s.&step-chr-a.&skip-whitespace;
     }
     when %s<last> && !is-endspace(%s<last>) && !is-prefix(%s<last>) {
       return preserve-endspace %s;
     }
     default {
       return skip-whitespace %s;
     }
  });
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
      %s = delete-chr-a %s;
    }
    die 'unterminated comment, stopped' unless %s<b>;
    if $bang_flag {
      @buf.pop while @buf && is-whitespace(@buf[*-1]);
    }
    for @buf -> $c {
      %s<output>.send($c);
    }
    return %s.&send-chr-out.&send-chr-out.&preserve-endspace;
  }

  # For regular comments: consume and discard
  loop {
    last if !%s<b> || (%s<a> eq '*' && %s<b> eq '/');
    %s = delete-chr-a %s;
  }

  die 'unterminated comment, stopped' unless %s<b>;

  # Remove the closing * and /
  %s = delete-chr-a %s;
  %s<a> = ' ';
  %s = collapse-whitespace %s;

  if (%s<last> && %s<b> &&
      ((is-alphanum(%s<last>) && ( is-alphanum(%s<b>) || %s<b> eq '.')) ||
       (%s<last> eq '+' && %s<b> eq '+') ||
       (%s<last> eq '-' && %s<b> eq '-') )) {
    return step-chr-a %s;
  } elsif (%s<last> && !is-prefix(%s<last>)) {
    return preserve-endspace %s;
  } else {
    return skip-whitespace %s;
  }
}

sub is-regex-start(Str $w) returns Bool {
  so $w eq any(<return typeof throw delete void case new in instanceof>);
}

multi sub process-comments(%s where {%s<lastnws> &&
                           (')].'.contains(%s<lastnws>) ||
                           (is-alphanum(%s<lastnws>) && !is-regex-start(%s<lastnws>)))}) returns Hash {
  %s.&step-chr-a.&collapse-whitespace.&process-conditional-comment;
}

multi sub process-comments(%s where {%s<a> eq '/' and %s<b> eq '.' }) returns Hash {
  %s.&collapse-whitespace.&step-chr-a;
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
  %s.&step-chr-a.&collapse-whitespace.&process-double-plus-minus;
}

multi sub process-char(%s where { is-alphanum(%s<a>) }) returns Hash {
  my @id;
  while %s<a> && is-alphanum(%s<a>) {
    @id.push(%s<a>);
    %s = delete-chr-a %s;
  }
  my Str $id = @id.join;

  if $id eq 'debugger' && %s<drop_debugger> {
    %s = collapse-whitespace %s;
    if %s<a> eq ';' {
      %s = delete-chr-a %s;
    }
    %s = skip-whitespace %s;
    %s<lastnws> = ';';
    %s<last> = ';';
    return %s;
  }

  if $id eq 'console' && %s<drop_console> {
    %s = collapse-whitespace %s;
    if %s<a> eq '.' {
      %s = delete-chr-a %s;
      %s = collapse-whitespace %s;
      my @method;
      while %s<a> && is-alphanum(%s<a>) {
        @method.push(%s<a>);
        %s = delete-chr-a %s;
      }
      my $method = @method.join;
      %s = collapse-whitespace %s;
      if %s<a> eq '(' {
        %s = skip-matching-paren %s, '(', ')';
        %s = collapse-whitespace %s;
        if %s<a> eq ';' {
          %s = delete-chr-a %s;
        }
        %s = skip-whitespace %s;
        %s<lastnws> = ';';
        %s<last> = ';';
        return %s;
      }
      %s<output>.send('console.' ~ $method);
    } else {
      %s<output>.send('console');
    }
    %s<lastnws> = 'console';
    %s<last> = 'console';
    %s = collapse-whitespace %s;
    %s = process-property-invocation %s;
    return %s;
  }

  given $id {
    when 'true'  {
      if (%s<lastnws> // '') eq any(<var let const>) || %s<lastnws> eq '.' {
        %s<output>.send('true');
      } elsif (%s<a> eq ':' || (is-whitespace(%s<a>) && %s<a> && %s<b> eq ':')) {
        %s<output>.send('true');
      } elsif (%s<a> eq '(') {
        %s<output>.send('true');
      } else {
        %s<output>.send('!0');
      }
    }
    when 'false' {
      if (%s<lastnws> // '') eq any(<var let const>) || %s<lastnws> eq '.' {
        %s<output>.send('false');
      } elsif (%s<a> eq ':' || (is-whitespace(%s<a>) && %s<a> && %s<b> eq ':')) {
        %s<output>.send('false');
      } elsif (%s<a> eq '(') {
        %s<output>.send('false');
      } else {
        %s<output>.send('!1');
      }
    }
    default      { %s<output>.send($id) }
  }
  %s<lastnws> = $id;
  %s<last>    = $id;
  %s.&collapse-whitespace.&process-property-invocation;
}

multi sub process-char(%s where { ';'.contains(%s<a>) }) returns Hash {
  if %s<b> eq '}' {
    %s = delete-chr-a %s;
    %s<last> = '}';
    return %s;
  }
  %s.&step-chr-a.&skip-whitespace;
}

multi sub process-char(%s where { ']})'.contains(%s<a>) }) returns Hash {
  %s.&step-chr-a.&preserve-endspace;
}

multi sub process-char(%s) returns Hash {
  %s.&step-chr-a.&skip-whitespace;
}

multi sub output-manager(Channel $output, Channel $stream) returns Promise {
  start {
    $output.list.map: -> $c {
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
    my Str $output_text = '';
    $output.list.map: -> $c {
      last if $c eq 'exit';
      $output_text ~= $c;
    }
    $output_text;
  }
}

sub js-minifier(:$input!, Str :$copyright = '', :$stream,
                Bool :$strip_debug = False,
                Bool :$keep_bang_comments = False,
                Bool :$drop_console = False,
                Bool :$drop_debugger = False,
                Bool :$nocompress = False) is export {

  my Str $input_new = ($input.WHAT ~~ Str ?? $input !! $input.readchars.chomp);

  my Str $preprocessed = $input_new;
  my %nocompress_blocks;

  if $strip_debug {
    $preprocessed = $preprocessed.subst(/ ';;;' <-[\n]>+ /, '', :g);
  }

  if $nocompress {
    my $processed = '';
    my $pos = 0;
    my $idx = 0;
    loop {
      my $begin = index($preprocessed, '/* BEGIN NOCOMPRESS */', $pos);
      last unless $begin.defined;
      $processed ~= substr($preprocessed, $pos, $begin - $pos);
      my $end = index($preprocessed, '/* END NOCOMPRESS */', $begin);
      die 'unterminated NOCOMPRESS block, stopped' unless $end.defined;
      my $block = substr($preprocessed, $begin + 22, $end - $begin - 22);
      my $key = "\x0N" ~ $idx ~ "N\x0";
      %nocompress_blocks{$key} = $block;
      $processed ~= $key;
      $pos = $end + 20;
      $idx++;
    }
    $processed ~= substr($preprocessed, $pos);
    $preprocessed = $processed;
  }

  my Str @input_list = $preprocessed.split("", :skip-empty).cache;

  unless @input_list {
    my $empty_result = $copyright ?? "/* $copyright */" !! '';
    return $empty_result unless $stream ~~ Channel;
    $stream.send($empty_result) if $empty_result.chars;
    $stream.close;
    return;
  }

  my %s = input             => @input_list,
          last_read_char    => 0,
          input_pos         => 0,
          output            => Channel.new,
          last              => Str,
          lastnws           => Str,
          line              => 1,
          column            => 0,
          keep_bang_comments => $keep_bang_comments,
          drop_console      => $drop_console,
          drop_debugger     => $drop_debugger;

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
    %s<input_pos> = $idx + 1;
    if %s<input_pos> >= @input_list.elems {
      %s<output>.send('exit');
      return $output.result unless $stream ~~ Channel;
      return;
    }
  }

  repeat {
    (%s<a>, %s<last_read_char>, %s<input_pos>) = get %s;
  } while (%s<a> && is-whitespace(%s<a>));
  (%s<b>, %s<last_read_char>, %s<input_pos>)   = get %s;
  (%s<c>, %s<last_read_char>, %s<input_pos>)   = get %s;
  (%s<d>, %s<last_read_char>, %s<input_pos>)   = get %s;

  start {
    while %s<a> {
      if (is-whitespace(%s<a>)) {
        die 'minifier bug: minify while loop starting with whitespace, stopped';
      }
      %s = process-char %s;
    };

    %s<output>.send: 'exit';
  }

  my $result = $output.result unless $stream ~~ Channel;

  if $nocompress && %nocompress_blocks {
    for %nocompress_blocks.kv -> $key, $value {
      $result = $result.subst($key, $value, :g);
    }
  }

  $result;
}

my &js-minify := &js-minifier;
