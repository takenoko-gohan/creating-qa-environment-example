package main

import (
	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/mysql"
	_ "github.com/golang-migrate/migrate/v4/source/file"
	"os"
	"time"
)

func main() {
	u := os.Getenv("DB_USER_NAME")
	p := os.Getenv("DB_USER_PASS")
	h := os.Getenv("DB_HOST")
	db := os.Getenv("DB_DATABASE")
	url := "mysql://" + u + ":" + p + "@tcp(" + h + ":3306)/" + db

	time.Sleep(10 * time.Second)

	m, err := migrate.New(
		"file://migrations",
		url,
	)
	if err != nil {
		panic(err)
	}

	// マイグレーションの実行
	m.Steps(2)
}
