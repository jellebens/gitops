## Bootstrap server

helm upgrade --install argocd-bootstrap bootstrap/ \
    -f .config/shared/values.yaml \ 
    -f .config/lab/values.yaml
