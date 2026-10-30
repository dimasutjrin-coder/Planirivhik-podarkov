function addGift() {
  const giftInput = document.getElementById('giftInput');
  const recipientInput = document.getElementById('recipientInput');
  const giftText = giftInput.value.trim();
  const recipientText = recipientInput.value.trim();
 
  // Валидация
  if (giftText === '') {
    alert('Введите название подарка!');
    return;
  }
 
  const giftList = document.getElementById('giftList');
  const li = document.createElement('li');
  li.innerHTML = `
    <span class="gift-name">${giftText}</span>
    <span class="recipient">для: ${recipientText || 'не указано'}</span>
    <button onclick="this.parentElement.remove()">Удалить</button>
  `;
  giftList.appendChild(li);
 
  giftInput.value = '';
  recipientInput.value = '';
  giftInput.focus();
}

