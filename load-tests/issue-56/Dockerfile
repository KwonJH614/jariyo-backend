FROM eclipse-temurin:17-jdk-alpine AS build

WORKDIR /workspace

COPY gradlew gradlew
COPY gradle gradle
COPY build.gradle settings.gradle ./
RUN chmod +x gradlew && ./gradlew --no-daemon dependencies

COPY src src
RUN ./gradlew --no-daemon bootJar

FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

COPY --from=build /workspace/build/libs/*.jar app.jar

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
