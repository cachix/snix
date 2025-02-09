WithFlipdot⇐

t ← {
  bool ⇐ "i8"
  # needs bound checking in wrapper (no c7 in CBQN) and zero byte appended
  charp ⇐ "*i8:c8"
  # assume size_t is at least 32bit
  size ⇐ "u32"
  # used for struct flipdot *
  hdl ⇐ "*"
}

ffi_flipdot_open  ← "libflipdot.so" •FFI  t.hdl‿"flipdot_open"‿t.charp‿"u16"
ffi_flipdot_close ← "libflipdot.so" •FFI     ""‿"flipdot_close"‿t.hdl
ffi_flipdot_send  ← "libflipdot.so" •FFI t.bool‿"flipdot_send"‿t.hdl‿"*u8"‿t.size

Compact ← +´∘(⌽ × 2⊸⋆∘↕∘≠)˘∘(∘‿8⊸⥊)

MakeFlipdot ← {
  host‿port‿w‿h:
  "Hostname must be ASCII"                   ! ∧´(@+127)≥host
  "Total pixel count must be divisible by 8" ! 0=8|w×h

  hdl ← FFI_flipdot_open (host∾@)‿port
  Close ⇐ {𝕤 ⋄ FFI_flipdot_close ⋈hdl}

  shape ⇐ h‿w
  empty ⇐ shape⥊0
  Send ⇐ {FFI_flipdot_send hdl∾(⊢⋈≠) Compact 𝕩}
}

# Inspired by Go's defer. Will execute 𝔽 after 𝔾 (passing 𝕨 and 𝕩 to each)
# even if an error occurs. If an error occurred, _defer_ will cause an
# assertion failure with the error message after executing 𝔾. This looses
# the original error location, though.
_defer_ ← {
  # can't use •CurrentError if 𝕩 is namespace: https://github.com/dzaima/cbqn/commit/d6609df82
  # to avoid this problem, always wrap 𝕩 in a list and unwrap it before calling 𝔾
  s‿r ← (1⊸⋈∘𝔾∘⊑)⎊(0⊸⋈∘•CurrentError) ⋈𝕩 ⋄ 𝔽 𝕩 ⋄ r⊣r!s;
  (𝕨⊸𝔽) _𝕣_ (𝕨⊸𝔾) 𝕩
}

WithFlipdot ← {{𝕩.Close @} _defer_ 𝕏 MakeFlipdot 𝕨}
