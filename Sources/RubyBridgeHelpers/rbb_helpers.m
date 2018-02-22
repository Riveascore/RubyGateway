//
//  rbb_helpers.m
//  RubyBridgeHelpers
//
//  Distributed under the MIT license, see LICENSE
//

@import CRuby;
#import "rbb_helpers.h"

//
// # Thunks for Exception Handling
//
// If there is an unhandled exception then Ruby crashes the process.
// We elect to never let this occur via RubyBridge APIs.
//
// The way to handle an exception in the C API is to wrap the throwy
// call in `rb_protect()`.
//
// (`rb_rescue()` does not handle all exceptions and the varargs `rb_rescue2()`
// doesn't make it through the clang importer so we'd need this kind of code
// anyway.)
//
//
// The normal flow goes:
//
//   client_1 -> rb_protect              // call from client code
//
//         client_2 <- rb_protect        // call from Ruby to client-provided throwy code
//
//            client_2 -> rb_something   // throwy call
//
//            client_2 <- rb_something   // unwind
//
//         client_2 -> rb_protect        // unwind
//
//   client_1 <- rb_protect              // unwind
//
//
// The exception flow goes:
//
//   client_1 -> rb_protect              // call from client code, Ruby does setjmp()
//
//         client_2 <- rb_protect        // call from Ruby to client-provided throwy code
//
//            client_2 -> rb_something   // throwy call
//
//                        rb_something   // EXCEPTION - longjump()
//
//   client_1 <- rb_protect              // unwind
//
// So, the key difference is that the bottom part of `client_2` and its return
// to rb_protect is skipped.
//
// Swift does not handle this: it assumes all functions will run to completion,
// or the process will exit.
//
// So we cannot implement `client_2` in Swift.  This file contains the implementations
// of `client_2` in regular C that is totally happy to be longjmp()d over.
//

static VALUE rbb_require_thunk(VALUE value)
{
    const char *fname = (const char *)(void *)value;
    return rb_require(fname);
}

VALUE rbb_require_protect(const char *fname, int *status)
{
    return rb_protect(rbb_require_thunk, (VALUE)(void *)fname, status);
}

static VALUE rbb_intern_thunk(VALUE value)
{
    const char *name = (const char *)(void *)value;
    return rb_intern(name);
}

ID rbb_intern_protect(const char * _Nonnull name, int * _Nullable status)
{
    return rb_protect(rbb_intern_thunk, (VALUE)(void *)name, status);
}

typedef struct
{
    VALUE   value;
    ID      id;
    VALUE (*fn)(VALUE, ID);
} Rbb_const_get_params;

static VALUE rbb_const_get_thunk(VALUE value)
{
    Rbb_const_get_params *params = (Rbb_const_get_params *)(void *)value;
    return params->fn(params->value, params->id);
}

VALUE rbb_const_get_protect(VALUE value, ID id, int * _Nullable status)
{
    Rbb_const_get_params params = { .value = value, .id = id, .fn = rb_const_get };
    return rb_protect(rbb_const_get_thunk, (VALUE)(void *)(&params), status);
}

VALUE rbb_const_get_at_protect(VALUE value, ID id, int * _Nullable status)
{
    Rbb_const_get_params params = { .value = value, .id = id, .fn = rb_const_get_at };
    return rb_protect(rbb_const_get_thunk, (VALUE)(void *)(&params), status);
}

//
// # Difficult Macros
//
// Some of the ruby.h API is too groady for the Swift Clang Importer to
// tolerate, usually because the C has difficult typecasts in it but sometimes
// for no obvious reason.
// 
// Some of these APIs are pretty useful so we reimplement them here providing
// a wrapper that looks type-safe for Swift to call.
//

int rbb_RB_BUILTIN_TYPE(VALUE value)
{
    return RB_BUILTIN_TYPE(value);
}

//
// # Numeric conversions
//

int          rbb_RB_NUM2INT(VALUE x)         { return RB_NUM2INT(x); }
unsigned int rbb_RB_NUM2UINT(VALUE x)        { return RB_NUM2UINT(x); }
VALUE        rbb_RB_INT2NUM(int v)           { return RB_INT2NUM(v); }
VALUE        rbb_RB_UINT2NUM(unsigned int v) { return RB_UINT2NUM(v); }

//
// # String methods
//
// rb_string_value() returns the to_str'd value and, if TYPE(v) not
// T_STRING, replaces the passed-in VALUE with the to-stringed value.
// We don't want such side-effects.
// Plus, it can raise if `to_str` is missing or `to_str` returns something
// that is not (ultimately) a string.
//

static VALUE rbb_string_value_thunk(VALUE v)
{
    return rb_string_value(&v);
}

VALUE rbb_string_value_protect(VALUE v, int * _Nullable status)
{
    return rb_protect(rbb_string_value_thunk, v, status);
}

// The RSTRING routines accesss the underlying structures
// that have too many unions for Swift to access safely.
long rbb_RSTRING_LEN(VALUE v)
{
    return RSTRING_LEN(v);
}

const char *rbb_RSTRING_PTR(VALUE v)
{
    return RSTRING_PTR(v);
}

//
// # Numeric conversion
//
// Ruby allows implicit signed -> unsigned conversion which is too
// slapdash for the Swift interface.  This seems to be remarkably
// baked into Ruby's numerics, so we do some 'orrible rooting around
// to figure it out.
//

static int rbb_numeric_ish_type(VALUE v)
{
    return NIL_P(v) ||
           FIXNUM_P(v) ||
           RB_TYPE_P(v, T_FLOAT) ||
           RB_TYPE_P(v, T_BIGNUM);
}

static VALUE rbb_num2ulong_thunk(VALUE v)
{
    // Drill down through `to_int` layers to find something
    // we can actually compare to zero.
    while (!rbb_numeric_ish_type(v))
    {
        v = rb_to_int(v);
    }

    // Now decide if this looks negative
    int negative = 0;

    if (FIXNUM_P(v))
    {
        negative = (RB_FIX2LONG(v) < 0);
    }
    else if (RB_TYPE_P(v, T_FLOAT))
    {
        negative = (NUM2DBL(v) < 0);
    }
    else if (RB_TYPE_P(v, T_BIGNUM))
    {   // don't @ me
        negative = ((RBASIC(v)->flags & RUBY_FL_USER1) == 0);
    }

    if (negative)
    {
        rb_raise(rb_eTypeError, "Value is negative and cannot be expressed as unsigned.");
    }

    return rb_num2ulong(v);
}

unsigned long rbb_num2ulong_protect(VALUE v, int * _Nullable status)
{
    return rb_protect(rbb_num2ulong_thunk, v, status);
}

//
// # Version constants
//
// These are exported as char [] which don't get imported
//

const char *rbb_ruby_version(void)
{
    return ruby_version;
}

const char *rbb_ruby_description(void)
{
    return ruby_description;
}

//
// # VALUE protection
//

Rbb_value * _Nonnull rbb_value_alloc(VALUE value)
{
    Rbb_value *box = malloc(sizeof(*box));
    if (box == NULL) {
        // No good way out here, don't want to make the RbEnv
        // initializers failable.
        abort();
    }
    box->value = value;

    // Subtlety - it would do no harm to register constants except that
    // in the scenario where Ruby is not functioning we use Qnil etc. instead
    // of actual values to avoid crashing.
    if (!RB_SPECIAL_CONST_P(value)) {
        rb_gc_register_address(&box->value);
    }
    return box;
}

Rbb_value *rbb_value_dup(const Rbb_value * _Nonnull box)
{
    return rbb_value_alloc(box->value);
}

void rbb_value_free(Rbb_value * _Nonnull box)
{
    if (!RB_SPECIAL_CONST_P(box->value)) {
        rb_gc_unregister_address(&box->value);
    }
    box->value = Qundef;
    free(box);
}
