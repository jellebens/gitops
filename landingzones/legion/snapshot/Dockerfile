# Legate with a snapshot of Legion's own documents in it. INTERIM.
#
# Legate reads a product's backlog and documents from a folder until it can
# read the main branch on GitHub (legion TSK-15, which waits for Legion's GitHub
# App). So that the praetor's view shows real data meanwhile, this puts
# Legion's docs/ at one commit on top of legate's image, where legate's
# configuration expects the product (/products/legion).
#
# What it shows is frozen at that commit: rebuild and bump
# legate.snapshot.commit and legate.image.tag to move it. The page names the
# commit. It goes when legate reads GitHub.
#
# Build from the ROOT of the legion repository, at the commit to show:
#
#   docker buildx build --builder default --load \
#     --platform linux/arm64 --provenance=false \
#     --build-arg LEGATE_IMAGE=harbor.lab.local/legion/legate:<version> \
#     -f <gitops>/landingzones/legion/snapshot/Dockerfile \
#     -t harbor.lab.local/legion/legate-snapshot:<version>-<commit, 7 chars> .
ARG LEGATE_IMAGE
FROM ${LEGATE_IMAGE}
COPY docs /products/legion/docs
