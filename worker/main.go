package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"gorm.io/driver/mysql"
	"gorm.io/gorm"
)

var client *sqs.Client

type messageBody struct {
	Name    string    `json:"name"`
	Message string    `json:"message"`
	Time    time.Time `json:"time"`
}

type Message struct {
	ID        uint   `gorm:"primary_key"`
	Name      string `gorm:"default:名無し"`
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
		log.Fatal(err)
	}

	client = sqs.NewFromConfig(cfg)
}

func main() {
	// db に接続
	dsn := os.Getenv("DB_USER_NAME") + ":" + os.Getenv("DB_USER_PASS") + "@tcp(" + os.Getenv("DB_HOST") + ":3306)/" + os.Getenv("DB_DATABASE") + "?charset=utf8mb4&parseTime=True&loc=Local"
	db, err := gorm.Open(mysql.Open(dsn), &gorm.Config{})
	if err != nil {
		log.Fatalf("ERROR failed to connect to db error: %s", err)
	}

	for {
		insertMessage(db)
	}
}

func insertMessage(db *gorm.DB) {
	// メッセージを取得
	messages, err := receive()
	if err != nil {
		log.Printf("ERROR failed to receive message error: %s", err)
		time.Sleep(10 * time.Second)

		return
	}

	if len(messages) > 0 {
		for _, message := range messages {
			log.Printf("INFO succeeded in receiving the message json: %s", *message.Body)
			body := new(messageBody)
			err = json.Unmarshal([]byte(*message.Body), body)
			if err != nil {
				log.Printf("ERROR failed to unmarshal json error: %s", err)
			}

			// db にメッセージをインサート
			err = db.Transaction(func(tx *gorm.DB) error {
				if err := tx.Create(&Message{
					Name:      body.Name,
					Message:   body.Message,
					CreatedAt: body.Time,
				}).Error; err != nil {
					log.Printf("ERROR failed to insert message error: %s", err)

					return err
				}

				if err := delete(message.ReceiptHandle); err != nil {
					log.Printf("ERROR failed to delete message error: %s", err)

					return err
				}

				log.Printf("INFO succeeded in deleting message json: %s", *message.Body)

				return nil
			})
			if err != nil {
				log.Printf("ERROR error occurred during processing within the transaction")

				return
			}

			log.Printf("INFO the processing in the transaction ended normally")
		}
	}
}

func receive() ([]types.Message, error) {
	// SQS からメッセージを受信
	res, err := client.ReceiveMessage(context.Background(), &sqs.ReceiveMessageInput{
		QueueUrl:            aws.String(os.Getenv("QUEUE_URL")),
		MaxNumberOfMessages: 1,
		WaitTimeSeconds:     20,
	})
	if err != nil {
		return nil, err
	}

	return res.Messages, nil
}

func delete(handle *string) error {
	// SQS からメッセージを削除
	_, err := client.DeleteMessage(context.Background(), &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(os.Getenv("QUEUE_URL")),
		ReceiptHandle: handle,
	})
	if err != nil {
		return err
	}

	return nil
}
