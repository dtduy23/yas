#!/bin/bash
# ===================================================================
# Service Mesh Test Plan - YAS Microservices
# Yêu cầu: Istio đã cài, sidecar đã inject (pods 2/2), mTLS STRICT
# ===================================================================

set -e
NAMESPACE="yas-dev"

echo "=============================================="
echo "  SERVICE MESH TEST PLAN - YAS PROJECT"
echo "  Namespace: $NAMESPACE"
echo "  Date: $(date)"
echo "=============================================="

# -----------------------------------------------
# TEST 1: Verify mTLS đang hoạt động
# -----------------------------------------------
echo ""
echo ">>> TEST 1: Verify mTLS"
echo "--- 1a. PeerAuthentication status ---"
kubectl get peerauthentication -n $NAMESPACE
echo ""

echo "--- 1b. Kiểm tra tất cả pods đều có sidecar (2/2) ---"
kubectl get pods -n $NAMESPACE -o custom-columns="NAME:.metadata.name,READY:.status.containerStatuses[*].ready,CONTAINERS:.spec.containers[*].name" | head -20
echo ""

echo "--- 1c. Kiểm tra Envoy TLS stats ---"
PRODUCT_POD=$(kubectl get pod -n $NAMESPACE -l app=product -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $PRODUCT_POD"
kubectl exec -n $NAMESPACE $PRODUCT_POD -c istio-proxy -- pilot-agent request GET stats 2>/dev/null | grep "ssl" | head -10
echo ""

# -----------------------------------------------
# TEST 2: Authorization Policy - ALLOW
# -----------------------------------------------
echo ">>> TEST 2: Authorization Policy"

ORDER_POD=$(kubectl get pod -n $NAMESPACE -l app=order -o jsonpath='{.items[0].metadata.name}')
PRODUCT_POD=$(kubectl get pod -n $NAMESPACE -l app=product -o jsonpath='{.items[0].metadata.name}')
NGINX_POD=$(kubectl get pod -n $NAMESPACE -l app=nginx -o jsonpath='{.items[0].metadata.name}')
CART_POD=$(kubectl get pod -n $NAMESPACE -l app=cart -o jsonpath='{.items[0].metadata.name}')
TAX_POD=$(kubectl get pod -n $NAMESPACE -l app=tax -o jsonpath='{.items[0].metadata.name}')

echo ""
echo "--- 2a. order -> cart (SHOULD BE ALLOWED) ---"
echo "Pod: $ORDER_POD -> cart:80"
RESULT=$(kubectl exec -n $NAMESPACE $ORDER_POD -c order -- wget -qO- --timeout=5 -S http://cart:80/ 2>&1 | head -5) || true
echo "$RESULT"
echo ""

echo "--- 2b. nginx -> cart (SHOULD BE ALLOWED) ---"
echo "Pod: $NGINX_POD -> cart:80"
RESULT=$(kubectl exec -n $NAMESPACE $NGINX_POD -c nginx -- curl -s -o /dev/null -w "HTTP Status: %{http_code}" --max-time 5 http://cart:80/) || true
echo "$RESULT"
echo ""

echo "--- 2c. tax -> cart (SHOULD BE DENIED - 403) ---"
echo "Pod: $TAX_POD -> cart:80"
RESULT=$(kubectl exec -n $NAMESPACE $TAX_POD -c tax -- wget -qO- --timeout=5 -S http://cart:80/ 2>&1 | head -5) || true
echo "$RESULT"
echo ""

echo "--- 2d. product -> payment (SHOULD BE DENIED - 403) ---"
echo "Pod: $PRODUCT_POD -> payment:80"
RESULT=$(kubectl exec -n $NAMESPACE $PRODUCT_POD -c product -- wget -qO- --timeout=5 -S http://payment:80/ 2>&1 | head -5) || true
echo "$RESULT"
echo ""

echo "--- 2e. order -> payment (SHOULD BE ALLOWED) ---"
echo "Pod: $ORDER_POD -> payment:80"
RESULT=$(kubectl exec -n $NAMESPACE $ORDER_POD -c order -- wget -qO- --timeout=5 -S http://payment:80/ 2>&1 | head -5) || true
echo "$RESULT"
echo ""

# -----------------------------------------------
# TEST 3: Retry Policy
# -----------------------------------------------
echo ">>> TEST 3: Retry Policy (VirtualService)"
echo "--- 3a. VirtualService cấu hình ---"
kubectl get virtualservice -n $NAMESPACE
echo ""

echo "--- 3b. Kiểm tra retry config trong Envoy ---"
kubectl exec -n $NAMESPACE $NGINX_POD -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | grep -A5 "retry_policy" | head -20
echo ""

echo "--- 3c. Envoy access logs (xem retry attempts) ---"
kubectl logs $CART_POD -n $NAMESPACE -c istio-proxy --tail=10 2>/dev/null
echo ""

echo "=============================================="
echo "  TEST COMPLETED"
echo "=============================================="
