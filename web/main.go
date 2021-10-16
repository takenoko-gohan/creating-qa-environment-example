package main

import (
	"context"
	"encoding/json"
	"html/template"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"gorm.io/driver/mysql"
	"gorm.io/gorm"
)

var client *sqs.Client

type indexData struct {
	Title    string
	Messages []Message
}

type messageBody struct {
	Name    string    `json:"name"`
	Message string    `json:"message"`
	Time    time.Time `json:"time"`
}

type Message struct {
	ID        uint `gorm:"primary_key"`
	Name      string
	Message   string
	CreatedAt time.Time
}

func init() {
	// ローカル環境の場合はエンドポイントを localstack に設定
	customResolver := aws.EndpointResolverFunc(func(service, region string) (aws.Endpoint, error) {
		if os.Getenv("APP_ENV") == "local" {
			return aws.Endpoint{
				PartitionID:   "aws",
				URL:           "http://localstack:4566",
				SigningRegion: "ap-northeast-1",
			}, nil
		}
		return aws.Endpoint{}, &aws.EndpointNotFoundError{}
	})

	cfg, err := config.LoadDefaultConfig(context.TODO(), config.WithEndpointResolver(customResolver))
	if err != nil {
		log.Fatalf("FATAL failed load aws config error: %s", err)
	}

	client = sqs.NewFromConfig(cfg)
}

func main() {
	http.HandleFunc("/", index)
	http.HandleFunc("/write", write)
	err := http.ListenAndServe(":80", nil)
	if err != nil {
		log.Fatalf("FATAL failed to start the server error: %s", err)
	}
}

func index(w http.ResponseWriter, r *http.Request) {
	// メソッドのチェック
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		w.Write([]byte("405 Method Not Allowed"))

		return
	}

	// db へ接続
	dsn := os.Getenv("DB_USER_NAME") + ":" + os.Getenv("DB_USER_PASS") + "@tcp(" + os.Getenv("DB_HOST") + ":3306)/" + os.Getenv("DB_DATABASE") + "?charset=utf8mb4&parseTime=True&loc=Local"
	db, err := gorm.Open(mysql.Open(dsn), &gorm.Config{})
	if err != nil {
		log.Printf("ERROR failed to connect to db error: %s", err)
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("500 Internal Server Error"))

		return
	}

	// メッセージの一覧を取得
	rows, err := db.Model(&Message{}).Select("name, message, created_at").Order("created_at").Rows()
	if err != nil {
		log.Printf("ERROR failed get Messages error: %s", err)
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("500 Internal Server Error"))

		return
	}
	defer rows.Close()

	var messages []Message
	for rows.Next() {
		var message Message
		rows.Scan(&message.Name, &message.Message, &message.CreatedAt)
		messages = append(messages, message)
	}

	// html をレスポンス
	tpl, err := template.ParseFiles("template/index.html")
	if err != nil {
		log.Printf("ERROR failed to parse the template: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("500 Internal Server Error"))

		return
	}
	err = tpl.Execute(w, &indexData{
		Title:    os.Getenv("APP_ENV") + " BBS",
		Messages: messages,
	})
	if err != nil {
		log.Printf("ERROR failed to execute the template: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("500 Internal Server Error"))

		return
	}
}

func write(w http.ResponseWriter, r *http.Request) {
	// メソッドのチェック
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		w.Write([]byte("405 Status Method Not Allowed"))

		return
	}

	// リクエストボディを取得
	r.ParseForm()
	form := r.PostForm

	body := &messageBody{
		Name:    form["name"][0],
		Message: form["message"][0],
		Time:    time.Now(),
	}

	log.Printf("INFO name: %s message: %s time: %s", body.Name, body.Message, body.Time)

	bytes, err := json.Marshal(body)
	if err != nil {
		log.Printf("ERROR: failed marshal: %s", err)
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("500 Internal Server Error"))

		return
	}

	// SQS にメッセージを送信
	_, err = client.SendMessage(context.Background(), &sqs.SendMessageInput{
		MessageBody:    aws.String(string(bytes)),
		QueueUrl:       aws.String(os.Getenv("QUEUE_URL")),
		MessageGroupId: aws.String("message"),
	})
	if err != nil {
		log.Printf("ERROR failed to send message json: %s error: %s", string(bytes), err)
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("500 Internal Server Error"))

		return
	}

	log.Printf("INFO succeeded in sending a message json: %s", string(bytes))

	// index にリダイレクト
	http.Redirect(w, r, "/", http.StatusFound)
}
