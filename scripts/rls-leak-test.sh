#!/usr/bin/env bash
# Tes kebocoran RLS lewat Supabase REST API langsung (bukan lewat Next.js).
# Pakai: SUPABASE_URL=... ANON_KEY=... bash scripts/rls-leak-test.sh
# Butuh: curl, jq. Membuat 2 user uji (email unik) — hapus manual dari dashboard setelahnya.
set -euo pipefail
: "${SUPABASE_URL:?}" "${ANON_KEY:?}"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (dapat: $2, harap: $3)"; fail=$((fail+1)); fi; }

signup() { # email -> "token user_id"
  curl -s "$SUPABASE_URL/auth/v1/signup" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"Testing123!\"}" | jq -r '[.access_token, .user.id] | @tsv'
}

stamp=$(date +%s)
read -r TOKEN_A ID_A < <(signup "rls-a-$stamp@example.com")
read -r TOKEN_B ID_B < <(signup "rls-b-$stamp@example.com")
[ "$TOKEN_A" != "null" ] || { echo "Signup gagal. Matikan 'Confirm email' di Supabase Auth dulu."; exit 1; }

api() { curl -s -o /tmp/rls_body -w "%{http_code}" "$@"; }
H_A=(-H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" -H "Content-Type: application/json")
H_B=(-H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" -H "Content-Type: application/json")
H_ANON=(-H "apikey: $ANON_KEY" -H "Content-Type: application/json")

# A membuat 1 data
code=$(api -X POST "$SUPABASE_URL/rest/v1/debts" "${H_A[@]}" -H "Prefer: return=representation" \
  -d '{"type":"owed_to_me","counterpart_name":"Rahasia A","amount":1000}')
check "A bisa insert data sendiri" "$code" "201"
DEBT_ID=$(jq -r '.[0].id' /tmp/rls_body)

# anon tanpa login
code=$(api "$SUPABASE_URL/rest/v1/debts?select=*" "${H_ANON[@]}")
check "anon SELECT ditolak (401/403)" "$([[ $code == 401 || $code == 403 ]] && echo ok || echo $code)" "ok"

# B tidak boleh lihat data A
api "$SUPABASE_URL/rest/v1/debts?select=*" "${H_B[@]}" >/dev/null
check "B SELECT semua -> 0 baris" "$(jq 'length' /tmp/rls_body)" "0"
api "$SUPABASE_URL/rest/v1/debts?id=eq.$DEBT_ID" "${H_B[@]}" >/dev/null
check "B SELECT by id milik A -> 0 baris" "$(jq 'length' /tmp/rls_body)" "0"

# B tidak boleh update / delete data A
api -X PATCH "$SUPABASE_URL/rest/v1/debts?id=eq.$DEBT_ID" "${H_B[@]}" -H "Prefer: return=representation" -d '{"amount":1}' >/dev/null
check "B UPDATE data A -> 0 baris terubah" "$(jq 'length' /tmp/rls_body)" "0"
api -X DELETE "$SUPABASE_URL/rest/v1/debts?id=eq.$DEBT_ID" "${H_B[@]}" -H "Prefer: return=representation" >/dev/null
check "B DELETE data A -> 0 baris terhapus" "$(jq 'length' /tmp/rls_body)" "0"

# B tidak boleh insert atas nama A
code=$(api -X POST "$SUPABASE_URL/rest/v1/debts" "${H_B[@]}" \
  -d "{\"user_id\":\"$ID_A\",\"type\":\"i_owe\",\"counterpart_name\":\"Palsu\",\"amount\":5}")
check "B INSERT dengan user_id = A ditolak (403)" "$code" "403"

# B tidak boleh "memindahkan" miliknya ke A / mengambil alih
# data A masih utuh
api "$SUPABASE_URL/rest/v1/debts?id=eq.$DEBT_ID&select=amount" "${H_A[@]}" >/dev/null
check "Data A tetap utuh (amount=1000)" "$(jq -r '.[0].amount' /tmp/rls_body)" "1000"

# bersih-bersih data uji
api -X DELETE "$SUPABASE_URL/rest/v1/debts?id=eq.$DEBT_ID" "${H_A[@]}" >/dev/null || true

echo "---"; echo "Lulus: $pass  Gagal: $fail"
[ "$fail" -eq 0 ]
