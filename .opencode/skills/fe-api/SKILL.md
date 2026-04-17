---
name: fe-api
description: 프론트엔드 API 함수 - fetch, axios, 타입 정의
compatibility: opencode
---

# API 함수 생성

## 위치
`src/features/{feature}/api/{name}Api.ts`

## 템플릿

```typescript
export async function getUser(id: number): Promise<User> {
  const res = await fetch(`/api/users/${id}`);
  return res.json();
}
```

## 체크리스트
- [ ] async/await
- [ ] 타입 정의
- [ ] export 문