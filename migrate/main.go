package main

import (
	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/mysql"
	_ "github.com/golang-migrate/migrate/v4/source/file"
	"os"
	"time"
)

func main() {
	p := os.Getenv("DB_ROOT_PASS")
	h := os.Getenv("DB_HOST")
	db := os.Getenv("DB_DATABASE")
	url := "mysql://root:" + p + "@tcp(" + h + ":3306)/" + db

	time.Sleep(10 * time.Second)

	m, err := migrate.New(
		"file://migrations",
		url,
	)
	if err != nil {
		panic(err)
	}

	m.Steps(2)
}
