/* Copyright (c) 2000-2003 Dave Rolsky
   All rights reserved.
   This program is free software; you can redistribute it and/or
   modify it under the same terms as Perl itself.  See the LICENSE
   file that comes with this distribution for more details. */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#define NEED_newCONSTSUB
#include "ppport.h"

/* not defined in 5.00503 _or_ ppport.h! */
#ifndef CopSTASHPV
#  ifdef USE_ITHREADS
#    define CopSTASHPV(c)         ((c)->cop_stashpv)
#  else
#    define CopSTASH(c)           ((c)->cop_stash)
#    define CopSTASHPV(c)         (CopSTASH(c) ? HvNAME(CopSTASH(c)) : Nullch)
#  endif /* USE_ITHREADS */
#endif /* CopSTASHPV */

#ifndef PERL_MAGIC_qr
#  define PERL_MAGIC_qr          'r'
#endif /* PERL_MAGIC_qr */

/* type constants */
#define SCALAR    1
#define ARRAYREF  2
#define HASHREF   4
#define CODEREF   8
#define GLOB      16
#define GLOBREF   32
#define SCALARREF 64
#define UNKNOWN   128
#define UNDEF     256
#define OBJECT    512

#define HANDLE    (GLOB | GLOBREF)
#define BOOLEAN   (SCALAR | UNDEF)

/* return data macros */
#define RETURN_ARRAY(ret) \
    STMT_START {                                      \
        switch(GIMME_V) {                             \
        case G_VOID:                                  \
            return;                                   \
        case G_ARRAY:                                 \
            EXTEND(SP, av_len(ret) + 1);              \
            for(i = 0; i <= av_len(ret); i ++) {      \
                PUSHs(*av_fetch(ret, i, 1));          \
            }                                         \
            break;                                    \
        case G_SCALAR:                                \
            XPUSHs(sv_2mortal(newRV_inc((SV*) ret))); \
            break;                                    \
        }                                             \
    } STMT_END


#define RETURN_HASH(ret) \
    STMT_START {                                      \
        HE* he;                                       \
        I32 keys;                                     \
        switch(GIMME_V) {                             \
        case G_VOID:                                  \
            return;                                   \
        case G_ARRAY:                                 \
            keys = hv_iterinit(ret);                  \
            EXTEND(SP, keys * 2);                     \
            while (he = hv_iternext(ret)) {           \
                PUSHs(HeSVKEY_force(he));             \
                PUSHs(HeVAL(he));                     \
            }                                         \
            break;                                    \
        case G_SCALAR:                                \
            XPUSHs(sv_2mortal(newRV_inc((SV*) ret))); \
            break;                                    \
        }                                             \
    } STMT_END

/* These macros are used because Perl 5.6.1 (and presumably 5.6.0)
   have problems if we try to die directly from XS code.  So instead,
   we just set some global variables and return 0.  For 5.6.0,
   validate(), validate_pos(), and validate_with() are thin Perl level
   wrappers which localize these globals, call the XS sub, and then
   check the globals afterwards. */

#if (PERL_VERSION == 6) /* 5.6.0 or 5.6.1 */
#  define FAIL(message, options)    \
            {                       \
              SV* perl_error;       \
              SV* perl_on_fail;     \
              SV* on_fail;          \
              perl_error = get_sv("Params::Validate::ERROR", 0);         \
              if (! perl_error)     \
                  croak("Cannot retrieve $Params::Validate::ERROR\n");   \
              perl_on_fail = get_sv("Params::Validate::ON_FAIL", 0);     \
              if (! perl_on_fail)  \
                  croak("Cannot retrieve $Params::Validate::ON_FAIL\n"); \
              SvSetSV(perl_error, message);                              \
              on_fail = get_on_fail(options);                            \
              SvSetSV(perl_on_fail, on_fail);                            \
              return 0;             \
            }
#else /* any other version*/
#  define FAIL(message, options)                \
        validation_failure(message, options);
#endif /* PERL_VERSION */

/* module initialization */
static void
bootinit()
{
  char* str;
  HV* stash;

  /* define constants */
  stash = gv_stashpv("Params::Validate", 1);
  newCONSTSUB(stash, "SCALAR", newSViv(SCALAR));
  newCONSTSUB(stash, "ARRAYREF", newSViv(ARRAYREF));
  newCONSTSUB(stash, "HASHREF", newSViv(HASHREF));
  newCONSTSUB(stash, "CODEREF", newSViv(CODEREF));
  newCONSTSUB(stash, "GLOB", newSViv(GLOB));
  newCONSTSUB(stash, "GLOBREF", newSViv(GLOBREF));
  newCONSTSUB(stash, "SCALARREF", newSViv(SCALARREF));
  newCONSTSUB(stash, "UNKNOWN", newSViv(UNKNOWN));
  newCONSTSUB(stash, "UNDEF", newSViv(UNDEF));
  newCONSTSUB(stash, "OBJECT", newSViv(OBJECT));
  newCONSTSUB(stash, "HANDLE", newSViv(HANDLE));
  newCONSTSUB(stash, "BOOLEAN", newSViv(BOOLEAN));
}

static bool
no_validation()
{
  SV* no_v;

  no_v = perl_get_sv("Params::Validate::NO_VALIDATION", 0);
  if (! no_v)
    croak("Cannot retrieve $Params::Validate::NO_VALIATION\n");

  return SvTRUE(no_v);
}
    
/* return type string that corresponds to typemask */
static SV*
typemask_to_string(IV mask)
{
  SV* buffer;
  IV empty = 1;

  buffer = sv_2mortal(newSVpv("", 0));

  if (mask & SCALAR) {
    sv_catpv(buffer, "scalar");
    empty = 0;
  }
  if (mask & ARRAYREF) {
    sv_catpv(buffer, empty ? "arrayref" : " arrayref");
    empty = 0;
  }
  if (mask & HASHREF) {
    sv_catpv(buffer, empty ? "hashref" : " hashref");
    empty = 0;
  }
  if (mask & CODEREF) {
    sv_catpv(buffer, empty ? "coderef" : " coderef");
    empty = 0;
  }
  if (mask & GLOB) {
    sv_catpv(buffer, empty ? "glob" : " glob");
    empty = 0;
  }
  if (mask & GLOBREF) {
    sv_catpv(buffer, empty ? "globref" : " globref");
    empty = 0;
  }
  if (mask & SCALARREF) {
    sv_catpv(buffer, empty ? "scalarref" : " scalarref");
    empty = 0;
  }
  if (mask & UNDEF) {
    sv_catpv(buffer, empty ? "undef" : " undef");
    empty = 0;
  }
  if (mask & OBJECT) {
    sv_catpv(buffer, empty ? "object" : " object");
    empty = 0;
  }
  if (mask & UNKNOWN) {
    sv_catpv(buffer, empty ? "unknown" : " unknown");
    empty = 0;
  }

  return buffer;
}

/* compute numberic datatype for variable */
static IV
get_type(SV* sv)
{
  IV type = 0;

  if (SvTYPE(sv) == SVt_PVGV) return GLOB;
  if (!SvOK(sv)) return UNDEF;
  if (!SvROK(sv)) return SCALAR;

  switch (SvTYPE(SvRV(sv))) {
    case SVt_NULL:
    case SVt_IV:
    case SVt_NV:
    case SVt_PV:
    case SVt_RV:
    case SVt_PVMG:
    case SVt_PVIV:
    case SVt_PVNV:
    case SVt_PVBM:
      type = SCALARREF;
      break;
    case SVt_PVAV:
      type = ARRAYREF;
      break;
    case SVt_PVHV:
      type = HASHREF;
      break;
    case SVt_PVCV:
      type = CODEREF;
      break;
    case SVt_PVGV:
      type = GLOBREF;
      break;
  }

  if (type) {
    if (sv_isobject(sv)) return type | OBJECT;
    return type;
  }

  /* I really hope this never happens */
  return UNKNOWN;
}

/* get an article for given string */
#if (PERL_VERSION >= 6) /* Perl 5.6.0+ */
static const char*
#else
static char*
#endif
article(SV* string)
{
  STRLEN len;
  char* rawstr;

  rawstr = SvPV(string, len);
  if (len) {
    switch(rawstr[0]) {
      case 'a':
      case 'e':
      case 'i':
      case 'o':
      case 'u':
        return "an";
    }
  }

  return "a";
}

static SV*
get_on_fail(HV* options)
{
  SV** temp;

  if (temp = hv_fetch(options, "on_fail", 7, 0)) {
    SvGETMAGIC(*temp);
    return *temp;
  } else {
    return &PL_sv_undef;
  }
}


#if (PERL_VERSION != 6) /* not used with 5.6.0 or 5.6.1 */
/* raises exception either using user-defined callback or using
   built-in method */
static void
validation_failure(SV* message, HV* options)
{
  SV** temp;
  SV* on_fail;

  if (temp = hv_fetch(options, "on_fail", 7, 0)) {
    SvGETMAGIC(*temp);
    on_fail = *temp;
  } else {
    on_fail = NULL;
  }

  /* use user defined callback if available */
  if (on_fail) {
    dSP;
    PUSHMARK(SP);
    XPUSHs(message);
    PUTBACK;
    perl_call_sv(on_fail, G_DISCARD);
  }

  /* by default resort to Carp::confess for error reporting */
  {
    dSP;
    perl_require_pv("Carp.pm");
    PUSHMARK(SP);
    XPUSHs(message);
    PUTBACK;
    perl_call_pv("Carp::croak", G_DISCARD);
  }

  return;
}
#endif /* PERL_VERSION */

/* get called subroutine fully qualified name */
static SV*
get_called(HV* options)
{
  SV** temp;

  if (temp = hv_fetch(options, "called", 6, 0)) {
    SvGETMAGIC(*temp);
    return *temp;
  } else {
    IV frame;
    SV* buffer;
    SV* caller;

    if (temp = hv_fetch(options, "stack_skip", 10, 0)) {
      SvGETMAGIC(*temp);
      frame = SvIV(*temp);
    } else {
      frame = 1;
    }

    /* With 5.6.0 & 5.6.1 there is an extra wrapper around the
       validation subs which we want to ignore */
#if (PERL_VERSION == 6)
    frame++;
#endif        

    buffer = sv_2mortal(newSVpvf("(caller(%d))[3]", (int) frame));

    caller = perl_eval_pv(SvPV_nolen(buffer), 1);
    if (SvTYPE(caller) == SVt_NULL) {
      sv_setpv(caller, "N/A");
    }

    return caller;
  }
}

/* UNIVERSAL::isa alike validation */
static IV
validate_isa(SV* value, SV* package, SV* id, HV* options)
{
  SV* buffer;

  /* quick test directly from Perl internals */
  if (sv_derived_from(value, SvPV_nolen(package))) return 1;

  buffer = sv_2mortal(newSVsv(id));
  sv_catpv(buffer, " to ");
  sv_catsv(buffer, get_called(options));
  sv_catpv(buffer, " was not ");
  sv_catpv(buffer, article(package));
  sv_catpv(buffer, " '");
  sv_catsv(buffer, package);
  sv_catpv(buffer, "' (it is ");
  sv_catpv(buffer, article(value));
  sv_catpv(buffer, " ");
  sv_catsv(buffer, value);
  sv_catpv(buffer, ")\n");
  FAIL(buffer, options);
}

/* UNIVERSAL::can alike validation */
static IV
validate_can(SV* value, SV* method, SV* id, HV* options)
{
  char* name;
  IV ok = 1;
  HV* pkg = NULL;

  /* some bits of this code are stolen from universal.c:
     XS_UNIVERSAL_can - beware that I've reformatted it and removed
     unused parts */
  if (SvGMAGICAL(value)) mg_get(value);

  if (!SvOK(value)) {
    if (!(SvROK(value) || (SvPOK(value) && SvCUR(value)))) ok = 0;
  }

  if (ok) {
    name = SvPV_nolen(method);
    if (SvROK(value)) {
      value = (SV*)SvRV(value);
      if (SvOBJECT(value)) pkg = SvSTASH(value);
    }
  } else {
    pkg = gv_stashsv(value, FALSE);
  }

  ok = 0;
  if (pkg) {
    GV* gv;

    gv = gv_fetchmethod_autoload(pkg, name, FALSE);
    if (gv && isGV(gv)) ok = 1;
  }
  /* end of stolen code */

  if (!ok) {
    SV* buffer;

    buffer = sv_2mortal(newSVsv(id));
    sv_catpv(buffer, " to ");
    sv_catsv(buffer, get_called(options));
    sv_catpv(buffer, " does not have the method: '");
    sv_catsv(buffer, method);
    sv_catpv(buffer, "'\n");
    FAIL(buffer, options);
  }

  return 1;
}

/* validates specific parameter using supplied parameter specification */
static IV
validate_one_param(SV* value, SV* params, HV* spec, SV* id, HV* options)
{
  SV** temp;

  /* check type */
  if (temp = hv_fetch(spec, "type", 4, 0)) {
    IV type;

    SvGETMAGIC(*temp);
    type = get_type(value);
    if (! (type & SvIV(*temp))) {
      SV* buffer;
      SV* is;
      SV* allowed;

      buffer = sv_2mortal(newSVsv(id));
      sv_catpv(buffer, " to ");
      sv_catsv(buffer, get_called(options));
      sv_catpv(buffer, " was ");
      is = typemask_to_string(type);
      allowed = typemask_to_string(SvIV(*temp));
      sv_catpv(buffer, article(is));
      sv_catpv(buffer, " '");
      sv_catsv(buffer, is);
      sv_catpv(buffer, "', which is not one of the allowed types: ");
      sv_catsv(buffer, allowed);
      sv_catpv(buffer, "\n");
      FAIL(buffer, options);
    }
  }

  /* check isa */
  if (temp = hv_fetch(spec, "isa", 3, 0)) {
    SvGETMAGIC(*temp);

    if (SvROK(*temp) && SvTYPE(SvRV(*temp)) == SVt_PVAV) {
      IV i;
      AV* array = (AV*) SvRV(*temp);

      for(i = 0; i <= av_len(array); i ++) {
        SV* package;

        package = *av_fetch(array, i, 1);
        SvGETMAGIC(package);
        if (! validate_isa(value, package, id, options))
          return 0;
      }
    } else {
      if (! validate_isa(value, *temp, id, options))
        return 0;
    }
  }

  /* check can */
  if (temp = hv_fetch(spec, "can", 3, 0)) {
    SvGETMAGIC(*temp);
    if (SvROK(*temp) && SvTYPE(SvRV(*temp)) == SVt_PVAV) {
      IV i;
      AV* array = (AV*) SvRV(*temp);

      for(i = 0; i <= av_len(array); i ++) {
        SV* method;

        method = *av_fetch(array, i, 1);
        SvGETMAGIC(method);

        if (! validate_can(value, method, id, options))
          return 0;
      }
    } else {
      if (! validate_can(value, *temp, id, options))
        return 0;
    }
  }

  /* let callbacks to do their tests */
  if (temp = hv_fetch(spec, "callbacks", 9, 0)) {
    SvGETMAGIC(*temp);
    if (SvROK(*temp) && SvTYPE(SvRV(*temp)) == SVt_PVHV) {
      HE* he;

      hv_iterinit((HV*) SvRV(*temp));
      while (he = hv_iternext((HV*) SvRV(*temp))) {
        if (SvROK(HeVAL(he)) && SvTYPE(SvRV(HeVAL(he))) == SVt_PVCV) {
          dSP;

          SV* ret;
          IV ok;
          IV count;

          ENTER;
          SAVETMPS;

          PUSHMARK(SP);
          EXTEND(SP, 2);
          PUSHs(value);
          PUSHs(sv_2mortal(newRV_inc(params)));
          PUTBACK;

          count = perl_call_sv(SvRV(HeVAL(he)), G_SCALAR);

          SPAGAIN;

          if (! count)
            croak("Validation callback did not return anything");

          ret = POPs;
          SvGETMAGIC(ret);
          ok = SvTRUE(ret);

          PUTBACK;
          FREETMPS;
          LEAVE;

          if (! ok) {
            SV* buffer;

            buffer = sv_2mortal(newSVsv(id));
            sv_catpv(buffer, " to ");
            sv_catsv(buffer, get_called(options));
            sv_catpv(buffer, " did not pass the '");
            sv_catsv(buffer, HeSVKEY_force(he));
            sv_catpv(buffer, "' callback\n");
            FAIL(buffer, options);
          }
        } else {
          SV* buffer;

          buffer = sv_2mortal(newSVpv("callback '", 0));
          sv_catsv(buffer, HeSVKEY_force(he));
          sv_catpv(buffer, "' for ");
          sv_catsv(buffer, get_called(options));
          sv_catpv(buffer, " is not a subroutine reference\n");
          FAIL(buffer, options);
        }
      }
    } else {
      SV* buffer;

      buffer = sv_2mortal(newSVpv("'callbacks' validation parameter for '", 0));
      sv_catsv(buffer, get_called(options));
      sv_catpv(buffer, " must be a hash reference\n");
      FAIL(buffer, options);
    }
  }

  if (temp = hv_fetch(spec, "regex", 5, 0)) {
    dSP;

    IV has_regex = 0;
    IV ok;
  
    SvGETMAGIC(*temp);
    if (SvPOK(*temp)) {
      has_regex = 1;
    } else if (SvROK(*temp)) {
      SV* svp;

      svp = (SV*)SvRV(*temp);

      if (SvMAGICAL(svp) && mg_find(svp, PERL_MAGIC_qr)) {
        has_regex = 1;
      }
    }

    if (!has_regex) {
      SV* buffer;

      buffer = sv_2mortal(newSVpv("'regex' validation parameter for '", 0));
      sv_catsv(buffer, get_called(options));
      sv_catpv(buffer, " must be a string or qr// regex\n");
      FAIL(buffer, options);
    }

    PUSHMARK(SP);
    EXTEND(SP, 2);
    PUSHs(value);
    PUSHs(*temp);
    PUTBACK;
    perl_call_pv("Params::Validate::_check_regex_from_xs", G_SCALAR);
    SPAGAIN;
    ok = POPi;
    PUTBACK;

    if (!ok) {
      SV* buffer;

      buffer = sv_2mortal(newSVsv(id));
      sv_catpv(buffer, " to ");
      sv_catsv(buffer, get_called(options));
      sv_catpv(buffer, " did not pass regex check\n");
      FAIL(buffer, options);
    }
  }

  return 1;
}

/* appends one hash to another (not deep copy) */
static void
append_hash2hash(HV* in, HV* out)
{
  HE* he;

  hv_iterinit(in);
  while (he = hv_iternext(in)) {
    if (!hv_store_ent(out, HeSVKEY_force(he),
                      SvREFCNT_inc(HeVAL(he)), HeHASH(he))) {
      SvREFCNT_dec(HeVAL(he));
      croak("Cannot add new key to hash");
    }
  }
}

/* convert array to hash */
static IV
convert_array2hash(AV* in, HV* options, HV* out)
{
  IV i;
  I32 len;

  len = av_len(in);
  if (len > -1 && len % 2 != 1) {
    SV* buffer;
    buffer = sv_2mortal(newSVpv("Odd number of parameters in call to ", 0));
    sv_catsv(buffer, get_called(options));
    sv_catpv(buffer, " when named parameters were expected\n");

    FAIL(buffer, options);
  }

  for(i = 0; i <= av_len(in); i += 2) {
    SV* key;
    SV* value;

    key = *av_fetch(in, i, 1);
    SvGETMAGIC(key);
    value = *av_fetch(in, i + 1, 1);
    SvGETMAGIC(value);
    if (! hv_store_ent(out, key, SvREFCNT_inc(value), 0)) {
      SvREFCNT_dec(value);
      croak("Cannot add new key to hash");
    }
  }

  return 1;
}

/* get current Params::Validate options */
static HV*
get_options(HV* options)
{
  HV* OPTIONS;
  HV* ret;
  SV** temp;
  char* pkg;

  ret = (HV*) sv_2mortal((SV*) newHV());

#if (PERL_VERSION == 6)
  pkg = SvPV_nolen(get_sv("Params::Validate::CALLER", 0));
#else
  /* gets caller's package name */
  pkg = CopSTASHPV(PL_curcop);
  if (pkg == Nullch) {
    pkg = "main";
  }
#endif
  /* get package specific options */
  OPTIONS = perl_get_hv("Params::Validate::OPTIONS", 1);
  if (temp = hv_fetch(OPTIONS, pkg, strlen(pkg), 0)) {
    SvGETMAGIC(*temp);
    if (SvROK(*temp) && SvTYPE(SvRV(*temp)) == SVt_PVHV) {
      if (options) {
        append_hash2hash((HV*) SvRV(*temp), ret);
      } else {
        return (HV*) SvRV(*temp);
      }
    }
  }
  if (options) {
    append_hash2hash(options, ret);
  }

  return ret;
}

static SV*
normalize_one_key(SV* key, SV* normalize_func, SV* strip_leading, IV ignore_case)
{
  SV* ret;
  STRLEN len_sl;
  STRLEN len;
  char *rawstr_sl;
  char *rawstr;

  ret = sv_2mortal(newSVsv(key));

  /* if normalize_func is provided, ignore the other options */
  if (normalize_func) {
    dSP;

    SV* key;

    PUSHMARK(SP);
    XPUSHs(ret);
    PUTBACK;
    if (! perl_call_sv(SvRV(normalize_func), G_SCALAR)) {
      croak("The normalize_keys callback did not return anything");
    }
    SPAGAIN;
    key = POPs;
    PUTBACK;

    if (! SvOK(key))
      croak("The normalize_keys callback did not return a defined value");

    return key;
  } else if (ignore_case || strip_leading) {
    if (ignore_case) {
      STRLEN i;

      rawstr = SvPV(ret, len);
      for (i = 0; i < len; i++) {
        /* should this account for UTF8 strings? */
        *(rawstr + i) = toLOWER(*(rawstr + i));
      }
    }

    if (strip_leading) {
      rawstr_sl = SvPV(strip_leading, len_sl);
      rawstr = SvPV(ret, len);

      if (len > len_sl && strnEQ(rawstr_sl, rawstr, len_sl)) {
        ret = sv_2mortal(newSVpvn(rawstr + len_sl, len - len_sl));
      }
    }
  }

  return ret;
}

static HV*
normalize_hash_keys(HV* p, SV* normalize_func, SV* strip_leading, IV ignore_case)
{
  SV* normalized;
  HE* he;
  HV* norm_p;

  if (!normalize_func && !ignore_case && !strip_leading) {
    return p;
  }

  norm_p = (HV*) sv_2mortal((SV*) newHV());
  hv_iterinit(p);
  while (he = hv_iternext(p)) {
    normalized =
      normalize_one_key(HeSVKEY_force(he), normalize_func, strip_leading, ignore_case);

    if (! hv_store_ent(norm_p, normalized, SvREFCNT_inc(HeVAL(he)), 0)) {
      SvREFCNT_dec(HeVAL(he));
      croak("Cannot add new key to hash");
    }
  }
  return norm_p;
}

static IV
validate_pos_depends(AV* p, AV* specs, HV* options)
{
  IV p_idx, d_idx;
  SV** depends;
  SV** p_spec;
  SV* buffer;
  SV* temp;

  for (p_idx = 0; p_idx <= av_len(p); p_idx++) {
    p_spec = av_fetch(specs, p_idx, 0);

    if (p_spec != NULL && SvROK(*p_spec) &&
        SvTYPE(SvRV(*p_spec)) == SVt_PVHV) {

      depends = hv_fetch((HV*) SvRV(*p_spec), "depends", 7, 0);

      if (! depends) return 1;

      if (SvROK(*depends)) {
        croak("Arguments to 'depends' for validate_pos() must be a scalar");
      }

      if (av_len(p) < SvIV(*depends) -1) {

        buffer =
          sv_2mortal(newSVpvf("Parameter #%d depends on parameter #%d, which was not given",
                              (int) p_idx + 1,
                              (int) SvIV(*depends)));

        FAIL(buffer, options);
      }
    }
  }
  return 1;
}

static IV
validate_named_depends(HV* p, HV* specs, HV* options)
{
  HE* he;
  HE* he1;
  SV* buffer;
  SV** depends_value;
  AV* depends_list;
  SV* depend_name;
  SV* temp;
  I32 d_idx;
    
  /* the basic idea here is to iterate through the parameters
   * (which we assumed to have already gone through validation
   * via validate_one_param()), and the check to see if that
   * parameter contains a "depends" spec. If it does, we'll
   * check if that parameter specified by depends exists in p
   */
  hv_iterinit(p);
  while (he = hv_iternext(p)) {
    he1 = hv_fetch_ent(specs, HeSVKEY_force(he), 0, HeHASH(he));
    
    if (he1 && SvROK(HeVAL(he1)) &&
        SvTYPE(SvRV(HeVAL(he1))) == SVt_PVHV) {

      if (hv_exists((HV*) SvRV(HeVAL(he1)), "depends", 7)) {

        depends_value = hv_fetch((HV*) SvRV(HeVAL(he1)), "depends", 7, 0);

        if (! depends_value) return 1;

        if (! SvROK(*depends_value)) {
          depends_list = (AV*) sv_2mortal((SV*) newAV());
          temp = sv_2mortal(newSVsv(*depends_value));
          av_push(depends_list,SvREFCNT_inc(temp));
        } else if (SvTYPE(SvRV(*depends_value)) == SVt_PVAV) {
          depends_list = (AV*) SvRV(*depends_value);
        } else {
          croak("Arguments to 'depends' must be a scalar or arrayref");
        }
    
        for (d_idx =0; d_idx <= av_len(depends_list); d_idx++) {

          depend_name = *av_fetch(depends_list, d_idx, 0);

          /* first check if the parameter to which this
           * depends on was given to us
           */
          if (!hv_exists(p, SvPV_nolen(depend_name),
                         SvCUR(depend_name))) {
            /* oh-oh, the parameter that this parameter
             * depends on is not available. Let's first check
             * if this is even valid in the spec (i.e., the
             * spec actually contains a spec for such parameter)
             */
            if (!hv_exists(specs, SvPV_nolen(depend_name),
                           SvCUR(depend_name))) {

              buffer =
                sv_2mortal(newSVpv("Following parameter specified in depends for '", 0));

              sv_catsv(buffer, HeSVKEY_force(he1));
              sv_catpv(buffer, "' does not exist in spec: ");
              sv_catsv(buffer, depend_name);
                
              croak(SvPV_nolen(buffer));
            } 
            /* if we got here, the spec was correct. we just
             * need to issue a regular validation failure
             */
            buffer = sv_2mortal(newSVpv( "Parameter '", 0));
            sv_catsv(buffer, HeSVKEY_force(he1));
            sv_catpv(buffer, "' depends on parameter '");
            sv_catsv(buffer, depend_name);
            sv_catpv(buffer, "', which was not given");
            FAIL(buffer, options);
          }
        }
      }
    }
  }
  return 1;
}

static IV
validate(HV* p, HV* specs, HV* options, HV* ret)
{
  AV* missing;
  AV* unmentioned;
  HE* he;
  HE* he1;
  IV ignore_case;
  SV* strip_leading;
  IV allow_extra;
  SV** temp;
  SV* normalize_func;

  if (temp = hv_fetch(options, "ignore_case", 11, 0)) {
    SvGETMAGIC(*temp);
    ignore_case = SvTRUE(*temp);
  } else {
    ignore_case = 0;
  }
  if (temp = hv_fetch(options, "strip_leading", 13, 0)) {
    SvGETMAGIC(*temp);
    if (SvOK(*temp)) strip_leading = *temp;
  } else {
    strip_leading = NULL;
  }

  if(temp = hv_fetch(options, "normalize_keys", 14, 0)) {
    SvGETMAGIC(*temp);
    if(SvROK(*temp) && SvTYPE(SvRV(*temp)) == SVt_PVCV) {
      normalize_func = *temp;
    } else {
      normalize_func = NULL;
    }
  } else {
    normalize_func = NULL;
  }

  if (normalize_func || ignore_case || strip_leading) {
    p = normalize_hash_keys(p, normalize_func, strip_leading, ignore_case);
    specs = normalize_hash_keys(specs, normalize_func, strip_leading, ignore_case);
  }

  if (temp = hv_fetch(options, "allow_extra", 11, 0)) {
    SvGETMAGIC(*temp);
    allow_extra = SvTRUE(*temp);
  } else {
    allow_extra = 0;
  }

  /* find extra parameters and validate good parameters */
  if (! no_validation())
    unmentioned = (AV*) sv_2mortal((SV*) newAV());

  hv_iterinit(p);
  while (he = hv_iternext(p)) {
    /* This may be related to bug #7387 on bugs.perl.org */
#if (PERL_VERSION == 5)
    if (! PL_tainting)
#endif
      SvGETMAGIC(HeVAL(he));

        
    /* put the parameter into return hash */
    if (GIMME_V != G_VOID) {
      if (!hv_store_ent(ret, HeSVKEY_force(he), SvREFCNT_inc(HeVAL(he)),
                        HeHASH(he))) {
        SvREFCNT_dec(HeVAL(he));
        croak("Cannot add new key to hash");
      }
    }

    if (!no_validation()) {
      /* check if this parameter is defined in spec and if it is
         then validate it using spec */
      he1 = hv_fetch_ent(specs, HeSVKEY_force(he), 0, HeHASH(he));
      if(he1) {
        if (SvROK(HeVAL(he1)) && SvTYPE(SvRV(HeVAL(he1))) == SVt_PVHV) {
          SV* buffer;
          HV* spec;
          char* value;

          spec = (HV*) SvRV(HeVAL(he1));
          buffer = sv_2mortal(newSVpv("The '", 0));
          sv_catsv(buffer, HeSVKEY_force(he));
          sv_catpv(buffer, "' parameter (");

          if(SvOK(HeVAL(he))) {
            value = SvPV_nolen(HeVAL(he));
            sv_catpv(buffer, "\"");
            sv_catpv(buffer, value);
            sv_catpv(buffer, "\"");
          } else {
            sv_catpv(buffer, "undef");
          }
          sv_catpv(buffer, ")");

          if (! validate_one_param(HeVAL(he), (SV*) p, spec, buffer, options))
            return 0;
        }
      } else if (! allow_extra) {
        av_push(unmentioned, SvREFCNT_inc(HeSVKEY_force(he)));
      }
    }

    if (!no_validation() && av_len(unmentioned) > -1) {
      SV* buffer;
      IV i;

      buffer = sv_2mortal(newSVpv("The following parameter", 0));
      if (av_len(unmentioned) != 0) {
        sv_catpv(buffer, "s were ");
      } else {
        sv_catpv(buffer, " was ");
      }
      sv_catpv(buffer, "passed in the call to ");
      sv_catsv(buffer, get_called(options));
      sv_catpv(buffer, " but ");
      if (av_len(unmentioned) != 0) {
        sv_catpv(buffer, "were ");
      } else {
        sv_catpv(buffer, "was ");
      }
      sv_catpv(buffer, "not listed in the validation options: ");
      for(i = 0; i <= av_len(unmentioned); i ++) {
        sv_catsv(buffer, *av_fetch(unmentioned, i, 1));
        if (i < av_len(unmentioned)) {
          sv_catpv(buffer, " ");
        }
      }
      sv_catpv(buffer, "\n");

      FAIL(buffer, options);
    }
  }

  validate_named_depends(p, specs, options);

  /* find missing parameters */
  if (! no_validation()) missing = (AV*) sv_2mortal((SV*) newAV());

  hv_iterinit(specs);
  while (he = hv_iternext(specs)) {
    HV* spec;

    /* get extended param spec if available */
    if (SvROK(HeVAL(he)) && SvTYPE(SvRV(HeVAL(he))) == SVt_PVHV) {
      spec = (HV*) SvRV(HeVAL(he));
    } else {
      spec = NULL;
    }

    /* test for parameter existance  */
    if (hv_exists_ent(p, HeSVKEY_force(he), HeHASH(he))) {
      continue;
    }

    /* parameter may not be defined but we may have default */
    if (spec && (temp = hv_fetch(spec, "default", 7, 0))) {
      SV* value;

      SvGETMAGIC(*temp);
      value = sv_2mortal(newSVsv(*temp));

      /* make sure that parameter is put into return hash */
      if (GIMME_V != G_VOID) {
        if (!hv_store_ent(ret, HeSVKEY_force(he),
                          SvREFCNT_inc(value), HeHASH(he))) {
          SvREFCNT_dec(value);
          croak("Cannot add new key to hash");
        }
      }

      continue;
    }

    /* find if missing parameter is mandatory */
    if (! no_validation()) {
      SV** temp;

      if (spec) {
        if (temp = hv_fetch(spec, "optional", 8, 0)) {
          SvGETMAGIC(*temp);
          if (SvTRUE(*temp)) continue;
        }
      } else if (!SvTRUE(HeVAL(he))) {
        continue;
      }
      av_push(missing, SvREFCNT_inc(HeSVKEY_force(he)));
    }
  }

  if (! no_validation() && av_len(missing) > -1) {
    SV* buffer;
    IV i;

    buffer = sv_2mortal(newSVpv("Mandatory parameter", 0));
    if (av_len(missing) > 0) {
      sv_catpv(buffer, "s ");
    } else {
      sv_catpv(buffer, " ");
    }
    for(i = 0; i <= av_len(missing); i ++) {
      sv_catpvf(buffer, "'%s'",
                SvPV_nolen(*av_fetch(missing, i, 0)));
      if (i < av_len(missing)) {
        sv_catpv(buffer, ", ");
      }
    }
    sv_catpv(buffer, " missing in call to ");
    sv_catsv(buffer, get_called(options));
    sv_catpv(buffer, "\n");

    FAIL(buffer, options);
  }

  return 1;
}

static SV*
validate_pos_failure(IV pnum, IV min, IV max, HV* options)
{
  SV* buffer;
  SV** temp;
  IV allow_extra;

  if (temp = hv_fetch(options, "allow_extra", 11, 0)) {
    SvGETMAGIC(*temp);
    allow_extra = SvTRUE(*temp);
  } else {
    allow_extra = 0;
  }

  buffer = sv_2mortal(newSViv(pnum + 1));
  if (pnum != 0) {
    sv_catpv(buffer, " parameters were passed to ");
  } else {
    sv_catpv(buffer, " parameter was passed to ");
  }
  sv_catsv(buffer, get_called(options));
  sv_catpv(buffer, " but ");
  if (!allow_extra) {
    if (min != max) {
      sv_catpvf(buffer, "%d - %d", (int) min + 1, (int) max + 1);
    } else {
      sv_catpvf(buffer, "%d", (int) max + 1);
    }
  } else {
    sv_catpvf(buffer, "at least %d", (int) min + 1);
  }
  if ((allow_extra ? min : max) != 0) {
    sv_catpv(buffer, " were expected\n");
  } else {
    sv_catpv(buffer, " was expected\n");
  }

  return buffer;
}

static IV
validate_pos(AV* p, AV* specs, HV* options, AV* ret)
{
  SV* buffer;
  SV* value;
  SV* spec;
  SV** temp;
  IV i;
  IV complex_spec;
  IV allow_extra;
  IV min;

  /* iterate through all parameters and validate them */
  min = -1;
  for (i = 0; i <= av_len(specs); i ++) {
    spec = *av_fetch(specs, i, 1);
    SvGETMAGIC(spec);
    complex_spec = (SvROK(spec) && SvTYPE(SvRV(spec)) == SVt_PVHV);

    if (complex_spec) {
      if (temp = hv_fetch((HV*) SvRV(spec), "optional", 8, 0)) {
        SvGETMAGIC(*temp);
        if (!SvTRUE(*temp)) min = i;
      } else {
        min = i;
      }
    } else {
      if (SvTRUE(spec)) min = i;
    }

    if (i <= av_len(p)) {
      value = *av_fetch(p, i, 1);
      SvGETMAGIC(value);
      if (!no_validation() && complex_spec) {
        buffer = sv_2mortal(newSVpvf("Parameter #%d (", (int) i + 1));
        if (SvOK(value)) {
          sv_catpv(buffer, "\"");
          sv_catpv(buffer, SvPV_nolen(value));
          sv_catpv(buffer, "\"");
        } else {
          sv_catpv(buffer, "undef");
        }
        sv_catpv(buffer, ")");

        if (! validate_one_param(value, (SV*) p, (HV*) SvRV(spec), buffer, options))
          return 0;
      }
      if (GIMME_V != G_VOID) av_push(ret, SvREFCNT_inc(value));
    } else if (complex_spec &&
               (temp = hv_fetch((HV*) SvRV(spec), "default", 7, 0))) {
      SvGETMAGIC(*temp);
      if (GIMME_V != G_VOID) av_push(ret, SvREFCNT_inc(*temp));
    } else {
      if (i == min) {
        SV* buffer;

        buffer = validate_pos_failure(av_len(p), min, av_len(specs), options);

        FAIL(buffer, options);
      }
    }
  }

  validate_pos_depends(p, specs, options);

  /* test for extra parameters */
  if (av_len(p) > av_len(specs)) {
    if (temp = hv_fetch(options, "allow_extra", 11, 0)) {
      SvGETMAGIC(*temp);
      allow_extra = SvTRUE(*temp);
    } else {
      allow_extra = 0;
    }
    if (allow_extra) {
      /* put all additional parameters into return array */
      if (GIMME_V != G_VOID) {
        for(i = av_len(specs) + 1; i <= av_len(p); i ++) {
          value = *av_fetch(p, i, 1);
          SvGETMAGIC(value);
          av_push(ret, SvREFCNT_inc(value));
        }
      }
    } else {
      SV* buffer;

      buffer = validate_pos_failure(av_len(p), min, av_len(specs), options);

      FAIL(buffer, options);
    }
  }

  return 1;
}

MODULE = Params::Validate               PACKAGE = Params::Validate

BOOT:
  bootinit();

void
_validate(p, specs)
  SV* p
  SV* specs

  PROTOTYPE: \@$

  PPCODE:

    HV* ret;
    AV* pa;
    HV* ph;
    HV* options;
    IV  ok;

    if (no_validation() && GIMME_V == G_VOID) XSRETURN(0);

    if (!SvROK(p) || !(SvTYPE(SvRV(p)) == SVt_PVAV)) {
      croak("Expecting array reference as first parameter");
    }
    if (!SvROK(specs) || !(SvTYPE(SvRV(specs)) == SVt_PVHV)) {
      croak("Expecting hash reference as second parameter");
    }

    pa = (AV*) SvRV(p);
    ph = NULL;
    if (av_len(pa) == 0) {
      /* we were called as validate( @_, ... ) where @_ has a
         single element, a hash reference */
      SV* value;

      value = *av_fetch(pa, 0, 1);
      SvGETMAGIC(value);
      if (SvROK(value) && SvTYPE(SvRV(value)) == SVt_PVHV) {
        ph = (HV*) SvRV(value);
      }
    }

    options = get_options(NULL);

    if (! ph) {
      ph = (HV*) sv_2mortal((SV*) newHV());

      if (! convert_array2hash(pa, options, ph) )
        XSRETURN(0);
    }

        
    if (GIMME_V != G_VOID) ret = (HV*) sv_2mortal((SV*) newHV());
    if (! validate(ph, (HV*) SvRV(specs), options, ret))
      XSRETURN(0);

    RETURN_HASH(ret);

void
_validate_pos(p, ...)
  SV* p

  PROTOTYPE: \@@

  PPCODE:

    AV* specs;
    AV* ret;
    IV i;

    if (no_validation() && GIMME_V == G_VOID) XSRETURN(0);

    if (!SvROK(p) || !(SvTYPE(SvRV(p)) == SVt_PVAV)) {
      croak("Expecting array reference as first parameter");
    }
    specs = (AV*) sv_2mortal((SV*) newAV());
    av_extend(specs, items);
    for(i = 1; i < items; i ++) {
      if (!av_store(specs, i - 1, SvREFCNT_inc(ST(i)))) {
        SvREFCNT_dec(ST(i));
        croak("Cannot store value in array");
      }
    }

    if (GIMME_V != G_VOID) ret = (AV*) sv_2mortal((SV*) newAV());
    if (! validate_pos((AV*) SvRV(p), specs, get_options(NULL), ret))
      XSRETURN(0);

    RETURN_ARRAY(ret);

void
_validate_with(...)

  PPCODE:

    HV* p;
    SV* params;
    SV* spec;
    IV i;

    if (no_validation() && GIMME_V == G_VOID) XSRETURN(0);

    /* put input list into hash */
    p = (HV*) sv_2mortal((SV*) newHV());
    for(i = 0; i < items; i += 2) {
      SV* key;
      SV* value;

      key = ST(i);
      if (i + 1 < items) {
        value = ST(i + 1);
      } else {
        value = &PL_sv_undef;
      }
      if (! hv_store_ent(p, key, SvREFCNT_inc(value), 0)) {
        SvREFCNT_dec(value);
        croak("Cannot add new key to hash");
      }
    }

    params = *hv_fetch(p, "params", 6, 1);
    SvGETMAGIC(params);
    spec = *hv_fetch(p, "spec", 4, 1);
    SvGETMAGIC(spec);

    if (SvROK(spec) && SvTYPE(SvRV(spec)) == SVt_PVAV) {
      if (SvROK(params) && SvTYPE(SvRV(params)) == SVt_PVAV) {
        AV* ret;
        IV  ok;

        if (GIMME_V != G_VOID) ret = (AV*) sv_2mortal((SV*) newAV());
        if (! validate_pos((AV*) SvRV(params), (AV*) SvRV(spec),
                           get_options(p), ret))
          XSRETURN(0);

        RETURN_ARRAY(ret);
      } else {
        croak("Expecting array reference in 'params'");
      }
    } else if (SvROK(spec) && SvTYPE(SvRV(spec)) == SVt_PVHV) {
      HV* hv;
      HV* ret;
      HV* options;

      options = get_options(p);

      if (SvROK(params) && SvTYPE(SvRV(params)) == SVt_PVHV) {
        hv = (HV*) SvRV(params);
      } else if (SvROK(params) && SvTYPE(SvRV(params)) == SVt_PVAV) {
        I32 hv_set = 0;

        /* Check to see if we have a one element array
           containing a hash reference */
        if (av_len((AV*) SvRV(params)) == 0) {
          SV** first_elem;

          first_elem = av_fetch((AV*) SvRV(params), 0, 0);

          if (first_elem && SvROK(*first_elem) &&
              SvTYPE(SvRV(*first_elem)) == SVt_PVHV) {

            hv = (HV*) SvRV(*first_elem);
            hv_set = 1;
          }
        }

        if (! hv_set) {
          hv = (HV*) sv_2mortal((SV*) newHV());

          if (! convert_array2hash((AV*) SvRV(params), options, hv))
            XSRETURN(0);
        }
      } else {
        croak("Expecting array or hash reference in 'params'");
      }

      if (GIMME_V != G_VOID)
        ret = (HV*) sv_2mortal((SV*) newHV());

      if (! validate(hv, (HV*) SvRV(spec), options, ret))
        XSRETURN(0);

      RETURN_HASH(ret);
    } else {
      croak("Expecting array or hash reference in 'spec'");
    }