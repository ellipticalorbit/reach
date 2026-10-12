docker ps -aq --filter "label=com.docker.compose.project=server" | xargs -r docker rm -f
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
