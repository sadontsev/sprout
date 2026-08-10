FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py clients.py cooldown.py p2s.py makerworld.py ./
EXPOSE 8911
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8911"]
