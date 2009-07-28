#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#define NEED_sv_2pv_flags
#include "ppport.h"

#include "hook_op_check.h"
#include "hook_op_ppaddr.h"

static int trycatch_debug = 0;

STATIC I32
dump_cxstack()
{
  I32 i;
  for (i = cxstack_ix; i >= 0; i--) {
    register const PERL_CONTEXT * const cx = cxstack+i;
    switch (CxTYPE(cx)) {
    default:
        continue;
    case CXt_SUB:
        printf("*** cx stack %d sub: %d\n", (int)i, CopLINE(cx->blk_oldcop));
        break;
    case CXt_EVAL:
        printf("*** cx stack %d eval: %d 0x%x %d\n", (int)i, CopLINE(cx->blk_oldcop),cx, cx);
        break;
    case CXt_NULL:
        printf("*** cx stack %d null\n", (int)i );
        break;
    case CXt_LOOP:
        printf("*** cx stack %d loop\n", (int)i );
        break;
    case CXt_SUBST:
        printf("*** cx stack %d subst\n", (int)i );
        break;
    case CXt_BLOCK:
        printf("*** cx stack %d block\n", (int)i );
        break;
    case CXt_FORMAT:
        printf("*** cx stack %d format\n", (int)i );
        break;
    }
  }
  return i;
}


STATIC OP* unwind_return (pTHX_ OP *op, void *user_data) {
  dSP;
  SV* ctx;
  CV *unwind;

  PERL_UNUSED_VAR(op);
  PERL_UNUSED_VAR(user_data);

  ctx = get_sv("TryCatch::CTX", 0);
  if (ctx) {
    XPUSHs( ctx );
    PUTBACK;
  } else {
    PUSHMARK(SP);
    PUTBACK;

    call_pv("Scope::Upper::SUB", G_SCALAR);
    if (trycatch_debug == 1) {
      printf("No ctx, making it up\n");
    }

    SPAGAIN;
  }

  if (trycatch_debug == 1) {
    printf("unwinding to %d\n", (int)SvIV(*sp));

  }


  /* Can't use call_sv et al. since it resets PL_op. */
  /* call_pv("Scope::Upper::unwind", G_VOID); */

  unwind = get_cv("Scope::Upper::unwind", 0);
  XPUSHs( (SV*)unwind);
  PUTBACK;

  return CALL_FPTR(PL_ppaddr[OP_ENTERSUB])(aTHXR);
}

STATIC OP* op_entertry (pTHX_ OP *op, void *user_data) {
  OP *ret;
  HV *try_scopes;

  ret = CALL_FPTR(PL_ppaddr[OP_ENTERTRY])(aTHXR);

  // Record this new context as a try-catch scope
  try_scopes = get_hv("TryCatch::TRY_SCOPES", 0);
  if (trycatch_debug & 2)
    printf("new trycatch scope %d\n", (int)(cxstack+cxstack_ix));

  hv_store_ent(try_scopes, newSViv((int)(cxstack + cxstack_ix)), newSViv(1), 0);

  return ret;
}

// This wont get called when we unwind, or die. But clean up where we can
STATIC OP* op_leavetry (pTHX_ OP *op, void *user_data) {
  HV *try_scopes;

  // Done with this scope, delete from hash
  try_scopes = get_hv("TryCatch::TRY_SCOPES", 0);
  hv_delete_ent(try_scopes, newSViv((int)(cxstack + cxstack_ix)), G_DISCARD, 0);

  return CALL_FPTR(PL_ppaddr[OP_LEAVETRY])(aTHXR);
}

STATIC OP* op_die_and_record (pTHX_ OP *op, void *user_data);

STATIC OP* op_die (pTHX_ OP *op, void *user_data) {
    I32 i;
    HV *try_scopes;
    SV *tmp_hk;
    bool found = 0;


    for (i = cxstack_ix; i >= 0; i--) {
      register const PERL_CONTEXT * const cx = cxstack+i;
      switch (CxTYPE(cx)) {
      default:
          continue;
      case CXt_EVAL:
          // The first eval scope we came across. See if we 'tagged' it.

          try_scopes = get_hv("TryCatch::TRY_SCOPES", 0);
          tmp_hk = newSViv((int)(cxstack + cxstack_ix));
          found = hv_exists_ent(try_scopes, tmp_hk, 0);

          // The top most eval on the stack was a TryCatch tagged one, so
          // handle the error specially
          if (found) {
            OP *ret;
            SV* old_diehook;

            // Set the SIG{__DIE__} handler that it should delegate to.
            old_diehook = get_sv("TryCatch::NEXT_SIG_HANDLER", 1);
            SvSetSV(old_diehook, PL_diehook);

            hv_delete_ent(try_scopes, tmp_hk, G_DISCARD, 0);
            PL_diehook = (SV*)get_cv("TryCatch::die_handler", 0);

            return CALL_FPTR(PL_ppaddr[OP_DIE])(aTHXR);
          }
          i = 0;
          break;
      }
    }

    return CALL_FPTR(PL_ppaddr[OP_DIE])(aTHXR);
}

// Copied from pp_sys.c on perl 5.8.8. Hrmmmm.

/* Hook the OP_RETURN iff we are in hte same file as originally compiling. */
STATIC OP* check_return (pTHX_ OP *op, void *user_data) {

  const char* file = SvPV_nolen( (SV*)user_data );
  const char* cur_file = CopFILE(&PL_compiling);
  if (strcmp(file, cur_file))
    return op;
  if (trycatch_debug == 2) {
    printf("hooking OP_return at %s:%d\n", file, CopLINE(&PL_compiling));
  }

  hook_op_ppaddr(op, unwind_return, NULL);
  return op;
}


STATIC OP* check_entertry(pTHX_ OP *op, void *user_data) {

  SV* eval_is_try = get_sv("TryCatch::NEXT_EVAL_IS_TRY", 0);

  if (SvOK(eval_is_try) && SvTRUE(eval_is_try)) {

    if (trycatch_debug == 2) {
      const char* cur_file = CopFILE(&PL_compiling);
      int is_try = SvIVx(eval_is_try);
      printf("enterytry op 0x%x try=%d at %s:%d\n",
             op, is_try, cur_file, CopLINE(PL_curcop) );
    }

    SvIV_set(eval_is_try, 0);
    hook_op_ppaddr(op, op_entertry, NULL);
  }
  return op;
}

// eval {} starts off as an OP_ENTEREVAL, and then the PL_check[OP_ENTEREVAL]
// returns a newly created ENTERTRY (and LEAVETRY) ops without calling the
// PL_check for these new ops into OP_ENTERTRY. How ever versions prior to perl
// 5.10.1 didn't call the PL_check for these new opes
STATIC OP* check_entereval (pTHX_ OP *op, void *user_data) {
  if (op->op_type == OP_LEAVETRY) {
    // Discarding the return value here is a little bit icky, but we dont do
    // anything but 'return op' anyway
    check_entertry(aTHX_ ((LISTOP*)op)->op_first, user_data);
    hook_op_ppaddr(op, op_leavetry, NULL);
    return op;
  }
  return op;
}

STATIC OP* check_die( pTHX_ OP* op, void *user_data) {
  hook_op_ppaddr(op, op_die, NULL);
  return op;
}

MODULE = TryCatch PACKAGE = TryCatch::XS

PROTOTYPES: DISABLE

void
install_return_op_check()
  CODE:
    /* Code stole from Scalar::Util::dualvar */
    UV id;
    char* file = CopFILE(&PL_compiling);
    STRLEN len = strlen(file);

    ST(0) = newSV(0);

    (void)SvUPGRADE(ST(0),SVt_PVNV);
    sv_setpvn(ST(0),file,len);

    id = hook_op_check( OP_RETURN, check_return, ST(0) );
#ifdef SVf_IVisUV
    SvUV_set(ST(0), id);
    SvIOK_on(ST(0));
    SvIsUV_on(ST(0));
#else
    SvIV_set(ST(0), id);
    SvIOK_on(ST(0));
#endif

    XSRETURN(1);

void
uninstall_return_op_check(id)
SV* id
  CODE:
#ifdef SVf_IVisUV
    UV uiv = SvUV(id);
#else
    UV uiv = SvIV(id);
#endif
    hook_op_check_remove(OP_RETURN, uiv);
  OUTPUT:

void dump_stack()
  CODE:
    dump_cxstack();
  OUTPUT:


void install_entertry_hook()
  CODE:
    hook_op_check( OP_ENTEREVAL, check_entereval, 0 );
    hook_op_check( OP_DIE,       check_die, 0 );
  OUTPUT:


BOOT:
{
  char *debug = getenv ("TRYCATCH_DEBUG");
  int lvl =0;
  if (debug && (lvl = atoi(debug)) && (lvl & (~1)) ) {
    trycatch_debug = lvl >> 1;
    printf("TryCatch XS debug enabled: %d\n", trycatch_debug);
  }
}
