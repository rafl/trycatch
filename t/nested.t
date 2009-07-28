use strict;
use warnings;
use Test::More tests => 5;

use TryCatch;

sub nested_1 {
  eval "123";
  try {
    try {
      TryCatch::XS::dump_stack;
      return "from nested_1";
    }
    catch ($e) {
    }
  }

  my $abc = 123;
  eval { 1; }
}

is( nested_1(), "from nested_1", "nested try");

sub nested_2 {
  try {
    nested_1();
    return "from nested_2";
  }
}

is( nested_2(), "from nested_2", "call nested try");

# same thing, but now we return from within the catch
sub nested_catch {
  try {      
      try {
        die "Some str\n";
      }
      catch ( $e ) {        
        return "return from nested catch";
      }
  }
  
  return "didn't catch";
}

is( nested_catch(), "return from nested catch", "nested catch" );

my $val;
try {
    try { die "Foo" }
    catch ($e) { die "$e" }
}
catch ($e) {
    $val = "$e";
} 
like($val, qr/^Foo at t[\/\\]nested.t line /, 
     "Nested try-catch in same function behaves");

sub nested_rethrow {
  try {      
      try {
        die "Some str\n";
      }
      catch (Str $err where { length $_ < 5 }) {        
        return "caught in inner TC";
      }
  }
  catch {
    return "caught in outer TC";
  }
  
  return "didn't catch";
}

is( nested_rethrow(), "caught in outer TC", "nested rethrow" );

# Test of the destructor checking.
sub nested_3 {
  eval "123";
  try {
    try {
      return "from nested_1";
    }
    catch ($e) {
    }
  }
  catch ($e) {}

  eval { 1; }
}

use Data::Dump qw/pp/; pp(\%TryCatch::TRY_SCOPES);
