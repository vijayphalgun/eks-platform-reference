# metrics-server backs the HorizontalPodAutoscaler in the sample app.
resource "helm_release" "metrics_server" {
  namespace  = "kube-system"
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.12.2"

  depends_on = [helm_release.karpenter]
}
