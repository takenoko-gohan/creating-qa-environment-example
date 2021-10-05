FROM hashicorp/terraform:1.0.7

WORKDIR /workspace

COPY ./ /workspace

VOLUME ["/workspace"]

ENTRYPOINT ["/bin/sh", "-c"]
CMD ["/workspace/apply.sh"]