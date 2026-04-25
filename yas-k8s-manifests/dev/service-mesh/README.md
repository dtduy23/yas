# Service Mesh - Istio Configuration for YAS Microservices

## Tổng quan

Dự án YAS sử dụng **Istio Service Mesh** trên Kubernetes để cung cấp:
1. **mTLS (Mutual TLS)**: Mã hóa toàn bộ traffic service-to-service
2. **Authorization Policy**: Kiểm soát service nào được phép gọi service nào
3. **Retry Policy**: Tự động retry khi service trả lỗi 5xx

## Kiến trúc

```
┌──────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                      │
│  ┌─────────────────────────────────────────────────────┐  │
│  │              Namespace: yas-dev                      │  │
│  │                                                      │  │
│  │  ┌─────────┐    mTLS    ┌──────────┐                │  │
│  │  │ nginx   │◄──────────►│ product  │                │  │
│  │  │ +envoy  │    🔒      │ +envoy   │                │  │
│  │  └────┬────┘            └──────────┘                │  │
│  │       │ mTLS                                        │  │
│  │       │  🔒                                         │  │
│  │  ┌────▼────┐    mTLS    ┌──────────┐                │  │
│  │  │  cart   │◄──────────►│  order   │                │  │
│  │  │ +envoy  │    🔒      │ +envoy   │                │  │
│  │  └─────────┘            └────┬─────┘                │  │
│  │                              │ mTLS                  │  │
│  │                              │  🔒                   │  │
│  │                         ┌────▼─────┐                │  │
│  │                         │ payment  │                │  │
│  │                         │ +envoy   │                │  │
│  │                         └──────────┘                │  │
│  │                                                      │  │
│  │  Istio Control Plane (istiod)                       │  │
│  │  Kiali Dashboard | Prometheus                       │  │
│  └─────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Prerequisite

- Kubernetes cluster đang chạy
- Istio 1.22.0 đã cài đặt (`istioctl install --set profile=demo -y`)
- Namespace `yas-dev` đã label `istio-injection=enabled`
- Kiali + Prometheus đã cài đặt

## Hướng dẫn triển khai từng bước

### Bước 1: Cài đặt Istio (nếu chưa)

```bash
# Download Istio
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.22.0 sh -
cd istio-1.22.0
export PATH=$PWD/bin:$PATH

# Cài Istio
istioctl install --set profile=demo -y

# Cài Kiali + Prometheus
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/addons/kiali.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/addons/prometheus.yaml

# Expose Kiali qua NodePort
kubectl patch svc kiali -n istio-system -p '{"spec": {"type": "NodePort", "ports": [{"port": 20001, "nodePort": 30020}]}}'
```

### Bước 2: Enable Sidecar Injection

```bash
# Label namespace
kubectl label namespace yas-dev istio-injection=enabled

# Restart tất cả pods để inject Envoy sidecar
kubectl rollout restart deployment -n yas-dev

# Verify: cột READY phải là 2/2 (app + sidecar)
kubectl get pods -n yas-dev
```

### Bước 3: Bật mTLS (Mutual TLS)

```bash
kubectl apply -f mtls-peer-auth.yaml

# Verify
kubectl get peerauthentication -n yas-dev
# Output: default   STRICT
```

**Giải thích:**
- `mode: STRICT` = bắt buộc TLS cho tất cả kết nối
- Envoy sidecar tự động xử lý certificate, mã hóa/giải mã
- Code ứng dụng KHÔNG cần thay đổi

### Bước 4: Tạo ServiceAccounts

```bash
kubectl apply -f service-accounts.yaml

# Gán ServiceAccount vào các deployment cần test
kubectl patch deployment order -n yas-dev -p '{"spec":{"template":{"spec":{"serviceAccountName":"order"}}}}'
kubectl patch deployment cart -n yas-dev -p '{"spec":{"template":{"spec":{"serviceAccountName":"cart"}}}}'
kubectl patch deployment product -n yas-dev -p '{"spec":{"template":{"spec":{"serviceAccountName":"product"}}}}'
kubectl patch deployment payment -n yas-dev -p '{"spec":{"template":{"spec":{"serviceAccountName":"payment"}}}}'
kubectl patch deployment nginx -n yas-dev -p '{"spec":{"template":{"spec":{"serviceAccountName":"nginx"}}}}'
kubectl patch deployment tax -n yas-dev -p '{"spec":{"template":{"spec":{"serviceAccountName":"tax"}}}}'

# Chờ pods restart (2-3 phút)
kubectl get pods -n yas-dev -w
```

### Bước 5: Áp dụng Authorization Policy

```bash
kubectl apply -f authz-policy.yaml

# Verify
kubectl get authorizationpolicy -n yas-dev
```

**Policy đã cấu hình:**

| Target Service | Allowed Callers | Denied (tất cả khác) |
|---------------|-----------------|----------------------|
| cart | order, storefront-bff, nginx | ❌ tax, product, rating... |
| product | cart, storefront-bff, backoffice-bff, nginx | ❌ order, tax, payment... |
| payment | order, nginx | ❌ product, cart, tax... |

### Bước 6: Áp dụng Retry Policy

```bash
kubectl apply -f retry-policy.yaml

# Verify
kubectl get virtualservice -n yas-dev
```

**Retry config:**
- `attempts: 3` — retry tối đa 3 lần
- `perTryTimeout: 5s` — mỗi lần retry timeout 5 giây
- `retryOn: 5xx,connect-failure,refused-stream` — retry khi lỗi 500, mất kết nối, hoặc bị từ chối

### Bước 7: Chạy Test Plan

```bash
chmod +x test-plan.sh
bash test-plan.sh
```

## Kết quả mong đợi

### Test 1 - mTLS
```
PeerAuthentication: default   STRICT
Tất cả pods: 2/2 (có Envoy sidecar)
```

### Test 2 - Authorization Policy
```
order  -> cart:    ✅ ALLOWED (200)
nginx  -> cart:    ✅ ALLOWED (200)
tax    -> cart:    ❌ DENIED  (403 RBAC: access denied)
product -> payment: ❌ DENIED  (403 RBAC: access denied)
order  -> payment: ✅ ALLOWED (200)
```

### Test 3 - Retry Policy
```
VirtualService: product-vs, cart-vs, order-vs, payment-vs
Retry config: 3 attempts, 5s timeout, retryOn=5xx
```

## Quan sát trên Kiali

1. Truy cập: `http://<GCP_EXTERNAL_IP>:30020`
2. Vào **Traffic Graph** → chọn namespace `yas-dev`
3. Bật **Display → Security** để hiện icon 🔒 (mTLS)
4. Bật **Display → Traffic Animation**
5. Các đường kết nối có 🔒 = mTLS enabled
6. Đường đỏ = bị DENY bởi Authorization Policy

## Cấu trúc file

```
yas-k8s-manifests/dev/service-mesh/
├── README.md                 # File này
├── mtls-peer-auth.yaml       # PeerAuthentication (mTLS STRICT)
├── service-accounts.yaml     # ServiceAccount cho các service
├── authz-policy.yaml         # Authorization Policy (ALLOW rules)
├── retry-policy.yaml         # VirtualService retry policy
└── test-plan.sh              # Script test tự động
```
