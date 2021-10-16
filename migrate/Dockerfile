FROM golang:1.15-buster as build

WORKDIR /go/src
COPY ./*.go ./
COPY ./go.* ./

RUN go build -o /go/bin/app

FROM gcr.io/distroless/base

WORKDIR /go

COPY ./migrations /go/migrations
COPY --from=build /go/bin/app /go/

CMD ["/go/app"]