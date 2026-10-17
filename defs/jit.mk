# Make recipes that deal with the rust code of YJIT and ZJIT.
#
# $(gnumake_recursive) adds the '+' prefix to pass down GNU make's
# jobserver resources to cargo/rustc as rust-lang.org recommends.
# Without it, certain make version trigger a warning. It does not
# add the prefix when `make --dry-run` so dry runs are indeed dry.

ifneq ($(JIT_CARGO_SUPPORT),no)

# Show Cargo progress when doing `make V=1`
CARGO_VERBOSE_0 = -q
CARGO_VERBOSE_1 =
CARGO_VERBOSE = $(CARGO_VERBOSE_$(V))

# Because of Cargo cache, if the actual binary is not changed from the
# previous build, the mtime is preserved as the cached file.
# This means the target is not updated actually, and it will need to
# rebuild at the next build.
RUST_LIB_TOUCH = touch $@

# NOTE: MACOSX_DEPLOYMENT_TARGET to match `rustc --print deployment-target` to avoid the warning below.
#    ld: warning: object file (target/debug/libjit.a(<libcapstone object>)) was built for
#    newer macOS version (15.2) than being linked (15.0)
# This limits us to an older set of macOS API in the rust code, but we don't use any.
$(RUST_LIB): $(srcdir)/ruby.rs target/.rustc-version
	$(Q)if [ '$(ZJIT_SUPPORT)' != no -a '$(YJIT_SUPPORT)' != no ]; then \
	    echo 'building YJIT and ZJIT ($(JIT_CARGO_SUPPORT:yes=release) mode)'; \
	elif [ '$(ZJIT_SUPPORT)' != no ]; then \
	    echo 'building ZJIT ($(JIT_CARGO_SUPPORT) mode)'; \
	elif [ '$(YJIT_SUPPORT)' != no ]; then \
	    echo 'building YJIT ($(JIT_CARGO_SUPPORT) mode)'; \
	fi
	$(gnumake_recursive)$(Q)CARGO_TARGET_DIR='$(CARGO_TARGET_DIR)' \
	    CARGO_TERM_PROGRESS_WHEN='never' \
	    MACOSX_DEPLOYMENT_TARGET=11.0 \
	    $(CARGO) $(CARGO_VERBOSE) build --manifest-path '$(top_srcdir)/Cargo.toml' $(CARGO_BUILD_ARGS)
	$(RUST_LIB_TOUCH)
else ifneq ($(strip $(RLIB_DIR)),) # combo build

$(RUST_LIB): $(srcdir)/ruby.rs target/.rustc-version
	$(ECHO) 'building $(@F)'
	$(gnumake_recursive)$(Q) $(RUSTC) --edition=2024 \
	    $(RUSTC_FLAGS) \
	    '-L$(@D)' \
	    --extern=yjit \
	    --extern=zjit \
	    --crate-type=staticlib \
	    --cfg 'feature="yjit"' \
	    --cfg 'feature="zjit"' \
	    '--out-dir=$(@D)' \
	    '$(top_srcdir)/ruby.rs'

# Absolute path to avoid VPATH ambiguity
JIT_RLIB = $(TOP_BUILD_DIR)/$(RLIB_DIR)/libjit.rlib
$(YJIT_RLIB): $(JIT_RLIB)
$(ZJIT_RLIB): $(JIT_RLIB)
$(JIT_RLIB): target/.rustc-version
	$(ECHO) 'building $(@F)'
	$(gnumake_recursive)$(Q) $(RUSTC) --crate-name=jit \
	    --edition=2024 \
	    $(JIT_RUST_FLAGS) \
	    $(RUSTC_FLAGS) \
	    '--out-dir=$(@D)' \
	    '$(top_srcdir)/jit/src/lib.rs'
endif # ifneq ($(JIT_CARGO_SUPPORT),no)

RUST_LIB_SYMBOLS = $(RUST_LIB:.a=).symbols
ifneq ($(findstring mingw,$(target_os)),)
# RUST_LIBOBJ is an archive here, and an archive nested inside the static
# libruby is invisible to the linker (mkmf's have_func probes link against
# it). Keep it out of the ar command line and merge its members instead;
# ADDLIB copes with the duplicate member names of Rust archives. The path is
# made relative because the MRI script is not subject to MSYS path conversion.
LIBRUBY_A_OBJS := $(filter-out $(RUST_LIBOBJ),$(LIBRUBY_A_OBJS))
LIBRUBY_A_MERGE = $(if $(RUST_LIB),printf 'OPEN %s\nADDLIB %s\nSAVE\nEND\n' '$@' '$(RUST_LIBOBJ:$(TOP_BUILD_DIR)/%=%)' | $(AR) -M,:)
# Export only Ruby's own symbols from the DLL, not the Rust internals (whose
# mangled names are not even valid in a .def file).
RUBYDEF_OBJS = $(LIBRUBY_A_OBJS) $(INITOBJS)

# binutils `ld -r` cannot partial-link the TLS directory the Rust std emits
# on PE ("unable to fill in DataDirectory[9]: _tls_used not defined
# correctly"). Instead, make a localized *copy of the archive*: objcopy
# rewrites each member's symbol table (no TLS-merging `ld -r` involved),
# hiding everything but rb_* so Rust's bundled compiler_builtins (lgamma_r,
# etc.) don't collide with Ruby's own missing/*.c. The linker then pulls
# members from this archive like any other library input.
# RUST_LIBOBJ is $(RUST_LIB:.a=.localized.a) here (set by configure, so that
# common.mk sees the same name when it expands the miniruby prerequisites).
# Unlike the Linux path we cannot `ld -r`-merge the archive first (PE TLS
# limitation), so we must NOT blanket-localize every non-rb_* symbol -- that
# would sever the cross-CGU references inside the Rust static lib (fmt impls,
# rust_eh_personality, ...). Instead localize ONLY the symbols that actually
# collide with Ruby's own definitions (compiler_builtins math intrinsics vs
# missing/lgamma_r.o etc.), computed as the intersection of the archive's
# globals with $(MISSING)'s globals.
$(RUST_LIBOBJ): $(RUST_LIB) $(MISSING)
	$(ECHO) 'localizing collisions in $(RUST_LIB) into $@ (mingw)'
	$(Q) $(CP) $(RUST_LIB) $@
	$(Q) for m in `ar t $@ | grep '\.dwo$$'`; do ar d $@ "$$m"; done
	$(Q) nm -g --defined-only $(MISSING) 2>/dev/null | awk 'NF==3 {print $$3}' | sort -u > $@.miss.syms
	$(Q) nm -g --defined-only $@ 2>/dev/null | awk 'NF==3 {print $$3}' | sort -u > $@.rust.syms
	$(Q) comm -12 $@.miss.syms $@.rust.syms > $@.collide.syms
	$(Q) if [ -s $@.collide.syms ]; then \
	        $(ECHO) "localizing collisions:" `tr '\n' ' ' < $@.collide.syms`; \
	        objcopy --localize-symbols=$@.collide.syms $@; \
	     fi
else
$(RUST_LIBOBJ): $(RUST_LIB)
	$(ECHO) 'partial linking $(RUST_LIB) into $@'
ifneq ($(findstring darwin,$(target_os)),)
	$(Q) $(CC) -nodefaultlibs -r -o $@ -exported_symbols_list $(RUST_LIB_SYMBOLS) $(RUST_LIB)
else
	$(Q) $(LD) -r -o $@ --whole-archive $(RUST_LIB)
	-$(Q) $(OBJCOPY) --wildcard --keep-global-symbol='$(SYMBOL_PREFIX)rb_*' $(@)
endif
endif

rust-libobj: $(RUST_LIBOBJ)
rust-lib: $(RUST_LIB)

rustc-version-check: target/.rustc-version

target/.rustc-version: PHONY
	$(eval prev_version := $(if $(wildcard $@),$(shell cat $@)))
	$(eval curr_version := $(shell $(RUSTC) -V | cut -d' ' -f2))
	$(eval clean := $(filter-out $(prev_version),$(curr_version)))
	$(if $(clean),$(ECHO) Cleaning $(@D) for rustc $(curr_version))
	$(if $(clean),$(Q)$(RMALL) $(@D))
	$(if $(clean),$(Q)$(MAKEDIRS) $(@D))
	$(if $(clean),$(Q)echo $(curr_version) > $@)

# For Darwin only: a list of symbols that we want the glommed Rust static lib to export.
# Unfortunately, using wildcard like '_rb_*' with -exported-symbol does not work, at least
# not on version 820.1. Assume llvm-nm, so XCode 8.0 (from 2016) or newer.
#
# The -exported_symbols_list pulls out the right archive members. Symbols not listed
# in the list are made private extern, which are in turn made local as we're using `ld -r`.
# Note, section about -keep_private_externs in ld's man page hints at this behavior on which
# we rely.
ifneq ($(findstring darwin,$(target_os)),)
$(RUST_LIB_SYMBOLS): $(RUST_LIB)
	$(Q) $(tooldir)/darwin-ar $(NM) --defined-only --extern-only $(RUST_LIB) | \
	sed -n -e 's/.* //' -e '/^$(SYMBOL_PREFIX)rb_/p' \
	-e '/^$(SYMBOL_PREFIX)rust_eh_personality/p' \
	> $@

$(RUST_LIBOBJ): $(RUST_LIB_SYMBOLS)
endif
