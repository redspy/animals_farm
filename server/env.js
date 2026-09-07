// 환경변수 읽기 한 곳. **전부 trim한다.**
//
// cmd의 `set VAR=값 && cmd`는 `&&` 앞 공백까지 값에 담는다. 이 함정에 두 번
// 물렸다: `deploy.bat`이 넘긴 TLS가 "off "가 되어 엄격 비교(`!== 'off'`)를 통과해
// 배포가 https로 떴고(헬스체크는 http라 실패), 같은 방식으로 `TLS_CERT="…pem "`이
// 되면 existsSync가 false가 되어 **조용히 http로 떨어진다**. `HOST=" 0.0.0.0"`은
// listen이 던진다.
//
// 별도 모듈인 이유: 인라인 헬퍼로 두면 다음에 누가 `process.env.X ||`로 되돌려도
// 아무 테스트도 깨지지 않는다(리뷰 지적). 여기에 유닛 테스트를 붙여 고정한다.

/** 값을 trim해서 돌려준다. 빈 문자열(또는 공백뿐)은 값이 없는 것으로 본다. */
export function envOf(source, key, fallback = '') {
  const raw = String((source || {})[key] ?? '').trim();
  return raw === '' ? fallback : raw;
}

/** process.env에 붙인 형태. 서버 코드는 이걸 쓴다. */
export function env(key, fallback = '') {
  return envOf(process.env, key, fallback);
}

/** `X=off`인지(대소문자·공백 무시). 스위치성 값의 공통 판정. */
export function envIsOff(key, source = process.env) {
  return envOf(source, key).toLowerCase() === 'off';
}
