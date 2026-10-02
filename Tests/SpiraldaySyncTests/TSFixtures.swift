// 다른 구현이 만든 고정 상호 운용 벡터 — Swift 가 같은 것을 읽고 같은 것을 만드는지 본다.
// 같은 프로토콜의 다른 구현(Windows 앱의 TypeScript 엔진 — 이 저장소에는 없다)이 만든 값을 그대로 둔다.
// 다시 만들 필요는 없다: 암호문은 무작위 nonce 를 써서 만들 때마다 바이트가 다르므로 고정 값으로 두고,
// 이 저장소만으로 확인할 수 있는 것은 BasicsTests.testDecryptsTypeScriptCiphertext 가 모두 본다
//   · 이 암호문을 아래 키 · 레코드 키로 풀면 recordPlain 이다 (XChaCha20-Poly1305 · gzip)
//   · 같은 앱 값 · 같은 0 시계로 Swift 가 만든 상태가 recordPlain 의 상태와 바이트까지 같다
//   · Swift 가 만든 암호문도 같은 평문으로 풀린다
// 입력: K = 00 01 … 1f, 레코드 키 d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2026-10-02,
// 앱의 하루 값(테스트에 그대로 있다)을 ZeroClock("0123456789abcdef") 로 비교 → 레코드 암호화 (gzip · libsodium).
// 메모는 줄마다 필드 m0 m1 m2 m+ 로 나뉜다
enum TSFixtures {
    static let recordCiphertext = "AZF4jmm2KiG6OW8Ud9ER4Ly8RHw8XGojxaq2cbI5eRbM__4cSZHR2W0nkQixtHdRNn4fuLBusqH9kJWclzJGOA0dfz7vdlF-MgR-gg8wf2c-YDXe4usu086W-aLjBiCcKw6RxwpAAjElj1LUubDWWvEYUi8R4J9_WlTWGZJtnnyRsD8_recYs21_cIQfsm8SafCz6S3CFtT8xm5X09maZvPyxmvvEC41V6O6fvvLzlebr1-E7UxsToOi7XVXx1vg6hklhV2e2kqnSUXahJiAq7erW_9GmY2SnTw7TNqp6MsSUNLC5-AaM0Cx9skcAz612r5cWz0AgGJAa5EfspttKuKowXQsUwfgcF3rWTvLhGelHg8nhkB-5Y8wcp8mfPxewPyZCRzhAPUQ9PjCJ13dOxcdAzu1lXIpfn1BuNWcWn6C06t3UeLd54WrHkGkWhd8jzQ9JgT8-o_350MYNuantMYbjwyIlRfiuXGercE"
    static let recordPlain = "{\"k\":\"d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2026-10-02\",\"s\":{\"c\":{\"tasks\":{\"AAAAAAAA-0000-4000-8000-000000000001\":{\"a\":\"00000000000000060123456789abcdef\",\"f\":{\"carriedFrom\":[null,\"00000000000000060123456789abcdef\"],\"cat\":[2,\"00000000000000060123456789abcdef\"],\"mark\":[1,\"00000000000000060123456789abcdef\"],\"row\":[0,\"00000000000000060123456789abcdef\"],\"text\":[\"회의 😀\",\"00000000000000060123456789abcdef\"]}}}},\"f\":{\"comment\":[\"비밀 일기 ✍️\",\"00000000000000010123456789abcdef\"],\"m0\":[\"메모\",\"00000000000000030123456789abcdef\"],\"s00\":[[3,3,3,3,3,3],\"00000000000000040123456789abcdef\"],\"theme\":[4,\"00000000000000020123456789abcdef\"],\"x:weird\":[{\"a\":[1.5,null]},\"00000000000000050123456789abcdef\"]}},\"v\":1}"
}
