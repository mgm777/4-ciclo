
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [module.gke]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  timeout = 900
}

resource "kubernetes_namespace" "togglemaster" {
  metadata {
    name = var.k8s_namespace
  }

  depends_on = [module.gke]
}

resource "kubernetes_service_account" "app" {
  for_each = toset(local.services)

  metadata {
    name      = "${each.value}-ksa"
    namespace = kubernetes_namespace.togglemaster.metadata[0].name

    annotations = {
      "iam.gke.io/gcp-service-account" = module.iam.service_account_emails[each.value]
    }
  }
}
